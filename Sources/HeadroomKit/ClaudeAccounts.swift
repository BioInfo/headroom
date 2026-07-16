import Foundation

/// In-app multi-account Claude management — the Swift port of the old machine-local
/// `~/scripts/claude-switch`, so Headroom is self-contained (no shell-out).
///
/// Claude Code keeps its OAuth creds in ONE slot: macOS login-Keychain item
/// "Claude Code-credentials" (+ a mirror at ~/.claude/.credentials.json). `/login` to a
/// different account OVERWRITES it. This stashes a full copy of each account's blob under
/// its own Headroom-owned Keychain item ("Headroom-claude-acct-<label>"), records which is
/// live in a pointer file, and "switches" by copying the chosen stash back into the live
/// slot — taking effect for NEW `claude` sessions.
///
/// Conventions (service names, pointer path, cred mirror, backup dir) are IDENTICAL to the
/// old shell tool, so the two remain interoperable if the CLI is ever run alongside.
/// Every write is verified by reading it back (gate on the artifact, not the exit code);
/// the token value is never logged.
public enum ClaudeAccounts {
    public static let liveService = "Claude Code-credentials"
    public static let stashPrefix = "Headroom-claude-acct-"

    // MARK: - provider-id <-> label

    /// True for the base `claude` card and any `claude-acct-<label>` account card.
    public static func isClaudeAccountID(_ id: String) -> Bool {
        id == "claude" || id.hasPrefix("claude-acct-")
    }
    /// The label for a `claude-acct-<label>` id, or nil for the base `claude` id / non-Claude.
    public static func label(forProviderID id: String) -> String? {
        id.hasPrefix("claude-acct-") ? String(id.dropFirst(stashPrefixCount)) : nil
    }
    public static func providerID(forLabel label: String) -> String { "claude-acct-\(label)" }
    private static let stashPrefixCount = "claude-acct-".count

    /// Normalize a user-typed name to a stash label: lowercase, spaces→dash, keep [a-z0-9-],
    /// collapse and trim dashes. Returns nil if nothing usable remains.
    public static func sanitizeLabel(_ raw: String) -> String? {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        let lowered = raw.lowercased().replacingOccurrences(of: " ", with: "-")
        var out = String(lowered.filter { allowed.contains($0) })
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? nil : out
    }

    // MARK: - files

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private static var pointerURL: URL { home.appendingPathComponent(".claude/.headroom-active-claude") }
    private static var credFileURL: URL { home.appendingPathComponent(".claude/.credentials.json") }
    private static var backupDir: URL { home.appendingPathComponent(".claude/.claude-switch-backups") }

    /// The label of the account currently in the live slot, per the pointer file, or nil.
    public static func activeLabel() -> String? {
        guard let s = try? String(contentsOf: pointerURL, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func setPointer(_ label: String) {
        try? label.write(to: pointerURL, atomically: true, encoding: .utf8)
    }

    private static func writeCredFile(_ blob: String) {
        let tmp = credFileURL.appendingPathExtension("tmp")
        guard let data = blob.data(using: .utf8), (try? data.write(to: tmp, options: .atomic)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        try? FileManager.default.removeItem(at: credFileURL)
        try? FileManager.default.moveItem(at: tmp, to: credFileURL)
    }

    /// Back up the current live blob before an overwrite; keep the last 20.
    private static func backupLive(_ blob: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"
        let f = backupDir.appendingPathComponent("live-\(df.string(from: Date())).json")
        if let data = blob.data(using: .utf8), (try? data.write(to: f, options: .atomic)) != nil {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.path)
        }
        // prune to the newest 20
        if let files = try? fm.contentsOfDirectory(at: backupDir, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter({ $0.lastPathComponent.hasPrefix("live-") }) {
            let sorted = files.sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return a > b
            }
            for old in sorted.dropFirst(20) { try? fm.removeItem(at: old) }
        }
    }

    // MARK: - keychain primitives (blob passes through argv locally; never logged)

    public static func readLive() -> String? { readSlot(service: liveService) }
    public static func readStash(_ label: String) -> String? { readSlot(service: stashPrefix + label) }

    private static func readSlot(service: String) -> String? {
        // In-process no-UI read first: no subprocess, and it can never pop the macOS auth
        // dialog or hang a background path (verified live: reads of both the live slot and
        // stashes succeed silently on an unlocked login keychain).
        switch KeychainRead.noUI(service: service) {
        case .found(let s): return s
        case .notFound:     return nil
        case .needsInteraction, .error:
            // Edge case (locked keychain / stricter ACL): fall back to /usr/bin/security,
            // which existing user grants often cover — timeout-guarded so a would-prompt
            // read degrades to nil instead of hanging.
            guard let out = security(["find-generic-password", "-s", service, "-w"], timeout: 10).out else { return nil }
            // `security -w` appends a newline; strip it so a readback compares equal to what we wrote.
            let v = out.trimmingCharacters(in: .newlines)
            return v.isEmpty ? nil : v
        }
    }

    /// Update the live slot IN PLACE (-U preserves the item's access ACL, so Claude Code
    /// keeps reading it without a Keychain prompt).
    @discardableResult private static func writeLive(_ blob: String) -> Bool {
        security(["add-generic-password", "-s", liveService, "-a", NSUserName(), "-w", blob, "-U"]).ok
    }
    /// Write a stash, granting /usr/bin/security itself access (-T) so future reads/updates
    /// from this tool don't prompt.
    @discardableResult private static func writeStash(_ label: String, _ blob: String) -> Bool {
        security(["add-generic-password", "-s", stashPrefix + label, "-a", NSUserName(),
                  "-w", blob, "-U", "-T", "/usr/bin/security"]).ok
    }
    @discardableResult private static func deleteStash(_ label: String) -> Bool {
        security(["delete-generic-password", "-s", stashPrefix + label]).ok
    }

    /// All stashed account labels, discovered from the login keychain (attribute list, not
    /// item data — no prompt), sorted.
    public static func listLabels() -> [String] {
        guard let out = security(["dump-keychain"], timeout: 20).out else { return [] }
        var labels = Set<String>()
        let pattern = "\"\(stashPrefix)([a-z0-9-]+)\""
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        for m in re.matches(in: out, range: NSRange(out.startIndex..., in: out)) {
            if let r = Range(m.range(at: 1), in: out) { labels.insert(String(out[r])) }
        }
        return labels.sorted()
    }

    /// Run `/usr/bin/security`; returns (ok, stdout). ok == exit 0. A `timeout` kills the
    /// child if it stalls (e.g. a would-prompt read on a background path) — pass one for
    /// every read; leave writes untimed, their prompt legitimately waits for the user.
    @discardableResult
    private static func security(_ args: [String], timeout: TimeInterval? = nil) -> (ok: Bool, out: String?) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = args
        let out = Pipe(); p.standardOutput = out
        p.standardError = FileHandle.nullDevice   // unread; `dump-keychain` is chatty on stderr
        do { try p.run() } catch { return (false, nil) }
        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if p.isRunning { p.terminate() }   // EOFs the pipe; the drain below returns
            }
        }
        // Drain stdout to EOF BEFORE waiting: `dump-keychain` writes far more than the 64KB
        // pipe buffer, so reading after waitUntilExit() would deadlock (child blocks on a full
        // pipe while we block on exit).
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus == 0, String(data: data, encoding: .utf8))
    }

    // MARK: - operations

    public struct OpError: Error, Sendable { public let message: String; public init(message: String) { self.message = message } }

    /// A read-only summary of the active account + every stash, for `headroom claude-accounts
    /// status` and diagnostics. Never prints a token.
    public static func statusReport() -> String {
        var lines: [String] = []
        lines.append("active (pointer): \(activeLabel() ?? "<unset>")")
        if let live = readLive() {
            lines.append("live slot       : \(ClaudeCreds.parse(live)?.summary() ?? "INVALID")")
        } else {
            lines.append("live slot       : <empty — not logged in>")
        }
        let labels = listLabels()
        if labels.isEmpty {
            lines.append("stashes         : <none — run: headroom claude-accounts capture <label>>")
        } else {
            for l in labels {
                let s = readStash(l).flatMap(ClaudeCreds.parse)?.summary() ?? "INVALID"
                let padded = l.padding(toLength: max(l.count, 10), withPad: " ", startingAt: 0)
                lines.append("stash \(padded) : \(s)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Stash the currently-logged-in account under `label` and mark it active. The label is
    /// the live account (it's what's in the slot), so this also sets the pointer.
    @discardableResult
    public static func capture(label rawLabel: String) -> Result<String, OpError> {
        guard let label = sanitizeLabel(rawLabel) else {
            return .failure(OpError(message: "Enter a name (letters, digits, dashes)."))
        }
        guard let blob = readLive() else {
            return .failure(OpError(message: "No Claude account is logged in — run `claude` to sign in first."))
        }
        guard let creds = ClaudeCreds.parse(blob) else {
            return .failure(OpError(message: "The live Claude slot isn't a valid credentials blob."))
        }
        guard writeStash(label, blob), readStash(label) == blob else {
            return .failure(OpError(message: "Couldn't save the account to the Keychain."))
        }
        setPointer(label)
        return .success("Saved “\(label)” — \(creds.summary())")
    }

    /// Make `label` the live account: capture-away the current one first (preserve a rotated
    /// refresh token), back up live, write the target into the live slot + cred file, verify.
    @discardableResult
    public static func switchTo(_ label: String) -> Result<String, OpError> {
        guard let target = readStash(label), ClaudeCreds.parse(target) != nil else {
            return .failure(OpError(message: "No saved account “\(label)”."))
        }
        if let live = readLive() {
            backupLive(live)
            if let cur = activeLabel(), ClaudeCreds.parse(live) != nil {
                _ = writeStash(cur, live)   // capture-away; best-effort (a bad blob just isn't stashed)
            }
        }
        guard writeLive(target) else {
            return .failure(OpError(message: "Couldn't write the live Keychain slot — try again."))
        }
        writeCredFile(target)
        guard readLive() == target else {
            return .failure(OpError(message: "Live slot didn't update (Keychain readback mismatch)."))
        }
        setPointer(label)
        let summ = ClaudeCreds.parse(target)?.summary() ?? ""
        return .success("Switched to “\(label)” — \(summ). Start a new `claude` session to use it.")
    }

    /// Delete a stash. Refuses the currently-active account (switch away first).
    @discardableResult
    public static func remove(_ label: String) -> Result<String, OpError> {
        if activeLabel() == label {
            return .failure(OpError(message: "“\(label)” is the active account — switch to another first."))
        }
        guard deleteStash(label) else {
            return .failure(OpError(message: "Couldn't remove “\(label)”."))
        }
        return .success("Removed “\(label)”.")
    }
}
