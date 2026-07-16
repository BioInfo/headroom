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

    /// Update the live slot IN PLACE. `SecItemUpdate` preserves the item's existing ACL, so
    /// Claude Code keeps reading it without a prompt of its own.
    ///
    /// In-process, not `/usr/bin/security`: macOS scopes Keychain trust to the *requesting
    /// binary*, so every shell-out asked as a fresh, unrelated process and re-prompted —
    /// three dialogs for one switch. As Headroom.app, one "Always Allow" is permanent.
    /// It also keeps the token off argv, where `ps` could read it.
    @discardableResult private static func writeLive(_ blob: String) -> Bool {
        KeychainWrite.upsert(service: liveService, account: NSUserName(), value: blob).isOK
    }
    @discardableResult private static func writeStash(_ label: String, _ blob: String) -> Bool {
        KeychainWrite.upsert(service: stashPrefix + label, account: NSUserName(), value: blob).isOK
    }
    @discardableResult private static func deleteStash(_ label: String) -> Bool {
        KeychainWrite.delete(service: stashPrefix + label, account: NSUserName()).isOK
    }

    // MARK: - identity index (the pointer is a cache; `account.uuid` is the fact)

    private static var indexURL: URL { home.appendingPathComponent(".claude/.headroom-claude-accounts.json") }

    public static func loadIndex() -> ClaudeAccountIndex {
        guard let data = try? Data(contentsOf: indexURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // First run (or pre-index install): seed the active label from the legacy pointer
            // so an existing setup keeps working. Identities fill in as accounts are verified.
            return ClaudeAccountIndex(activeLabel: activeLabel())
        }
        return ClaudeAccountIndex.deserialize(obj)
    }

    public static func saveIndex(_ idx: ClaudeAccountIndex) {
        guard let data = try? JSONSerialization.data(withJSONObject: idx.serialized(),
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: indexURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
        // Keep the legacy pointer in step so `~/scripts/claude-switch` stays interoperable.
        if let a = idx.activeLabel { setPointer(a) }
    }

    /// Resolve who a credential blob belongs to. Read-only and non-rotating, so it is always
    /// safe to call. Returns nil when the blob's access token is expired or the network is
    /// down — callers MUST treat nil as "unknown", never as "not that account".
    public static func identify(blob: String) async -> ClaudeIdentity? {
        guard let creds = ClaudeCreds.parse(blob) else { return nil }
        if case .success(let id) = await ClaudeProfile.fetch(accessToken: creds.accessToken) { return id }
        return nil
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
    /// Reports the VERIFIED account behind each slot, not just the label — a label is a claim
    /// and the whole class of bugs here came from believing it. An account whose access token
    /// has expired is reported as unverifiable rather than assumed (we won't refresh it just
    /// to look, since a refresh rotates).
    public static func statusReport() async -> String {
        var lines: [String] = []
        let idx = loadIndex()
        lines.append("active (cached) : \(idx.activeLabel ?? activeLabel() ?? "<unset>")")
        if let live = readLive() {
            let who = await identify(blob: live)?.summary() ?? "unverifiable (expired token or offline)"
            lines.append("live slot       : \(ClaudeCreds.parse(live)?.summary() ?? "INVALID")")
            lines.append("live account    : \(who)")
            if let liveID = await identify(blob: live), let owner = idx.label(forUUID: liveID.accountUUID) {
                lines.append("live is stash   : \(owner)")
            } else {
                lines.append("live is stash   : <not saved under any name>")
            }
        } else {
            lines.append("live slot       : <empty — not logged in>")
        }
        let labels = listLabels()
        if labels.isEmpty {
            lines.append("stashes         : <none — run: headroom claude-accounts capture <label>>")
        } else {
            for l in labels {
                let s = readStash(l).flatMap(ClaudeCreds.parse)?.summary() ?? "INVALID"
                let who = idx.accounts[l]?.email ?? idx.accounts[l]?.uuid ?? "unknown — run: headroom claude-accounts reconcile"
                let padded = l.padding(toLength: max(l.count, 10), withPad: " ", startingAt: 0)
                lines.append("stash \(padded) : \(s)")
                lines.append("      \(padded) → \(who)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Bind every stash we can verify to its real `account.uuid`. Read-only and non-rotating:
    /// a stash whose access token has already expired stays "unknown" rather than being
    /// refreshed behind the user's back (a refresh rotates, and an unpersisted rotation
    /// strands the account). Self-heals an index that predates this scheme.
    @discardableResult
    public static func reconcile() async -> ClaudeAccountIndex {
        var idx = loadIndex()
        for label in listLabels() {
            guard let blob = readStash(label) else { continue }
            if let id = await identify(blob: blob) { idx.record(label: label, identity: id) }
        }
        if let live = readLive(), let liveID = await identify(blob: live),
           let owner = idx.label(forUUID: liveID.accountUUID) {
            idx.activeLabel = owner   // the pointer may disagree; the uuid wins
        }
        saveIndex(idx)
        return idx
    }

    /// Stash the currently-logged-in account under `label` and mark it active, recording the
    /// verified `account.uuid` so later capture-aways can route by identity instead of a claim.
    @discardableResult
    public static func capture(label rawLabel: String) async -> Result<String, OpError> {
        guard let label = sanitizeLabel(rawLabel) else {
            return .failure(OpError(message: "Enter a name (letters, digits, dashes)."))
        }
        guard let blob = readLive() else {
            return .failure(OpError(message: "No Claude account is logged in — run `claude` to sign in first."))
        }
        guard let creds = ClaudeCreds.parse(blob) else {
            return .failure(OpError(message: "The live Claude slot isn't a valid credentials blob."))
        }
        let identity = await identify(blob: blob)
        var idx = loadIndex()
        // Refuse to file this account under a second name — that's how a "personal" stash ends
        // up holding the business account and one of the two silently becomes unreachable.
        if let identity, let existing = idx.label(forUUID: identity.accountUUID), existing != label {
            return .failure(OpError(message: "That account is already saved as “\(existing)” (\(identity.summary())). Rename it instead of saving it twice."))
        }
        guard writeStash(label, blob), readStash(label) == blob else {
            return .failure(OpError(message: "Couldn't save the account to the Keychain."))
        }
        if let identity { idx.record(label: label, identity: identity) }
        idx.activeLabel = label
        saveIndex(idx)
        let who = identity?.summary() ?? creds.summary()
        return .success("Saved “\(label)” — \(who)")
    }

    /// Make `label` the live account.
    ///
    /// The order here is the whole fix, and every step is load-bearing:
    ///  1. **Verify who is live** via `account.uuid` — never the pointer, which `/login`
    ///     silently invalidates. Unknown ⇒ refuse; a blind capture-away overwrites a *different*
    ///     account's credentials.
    ///  2. **Capture-away by identity**, into the stash that actually holds that uuid.
    ///  3. **Refresh the target before writing it.** A stash is a frozen copy of a rotating
    ///     credential and is very likely already void — writing it into the live slot is what
    ///     logged people out (replaying a rotated refresh token gets the family revoked).
    ///  4. **Persist the rotation to the stash BEFORE the live write**, so a crash mid-switch
    ///     can't strand the account with a token nobody recorded.
    ///  5. Write live + cred mirror, verify by readback.
    @discardableResult
    public static func switchTo(_ label: String) async -> Result<String, OpError> {
        guard let targetBlob = readStash(label), ClaudeCreds.parse(targetBlob) != nil else {
            return .failure(OpError(message: "No saved account “\(label)”."))
        }
        var idx = loadIndex()

        // 1-2. Identify the live account, then file it where it actually belongs.
        if let live = readLive(), ClaudeCreds.parse(live) != nil {
            backupLive(live)
            guard let liveID = await identify(blob: live) else {
                return .failure(OpError(message: "Couldn't confirm which account is logged in right now (expired token, or no network). Not switching — guessing here could overwrite another saved account's credentials."))
            }
            if let target = idx.accounts[label], target.uuid == liveID.accountUUID {
                idx.activeLabel = label; saveIndex(idx)
                return .success("Already signed in as “\(label)” (\(liveID.summary())).")
            }
            // An install that predates the index has labels but no uuids, so nothing resolves
            // yet. Bind them once, on demand, rather than making an existing multi-account user
            // re-save every account to earn a switch. Read-only, so it can't do harm.
            if idx.label(forUUID: liveID.accountUUID) == nil, idx.accounts.isEmpty {
                idx = await reconcile()
            }
            if let awayLabel = idx.label(forUUID: liveID.accountUUID) {
                if writeStash(awayLabel, live) { idx.record(label: awayLabel, identity: liveID) }
            } else {
                return .failure(OpError(message: "The account signed in right now (\(liveID.summary())) isn't saved yet. Save it first (Settings → Claude accounts → Add current account), or switching would lose its sign-in."))
            }
        }

        // 3. Refresh the target — never write a frozen token into the live slot.
        guard let targetCreds = ClaudeCreds.parse(targetBlob),
              let targetRefresh = targetCreds.refreshToken else {
            return .failure(OpError(message: "Saved account “\(label)” has no refresh token — sign in again with `claude` and re-save it."))
        }
        let fresh: ClaudeRefresh.Fresh
        switch await ClaudeRefresh.refresh(refreshToken: targetRefresh) {
        case .success(let f):
            fresh = f
        case .failure(.revoked):
            return .failure(OpError(message: "“\(label)” has been signed out (its saved token is no longer valid). Run `claude` and sign in to that account, then save it again."))
        case .failure(let e):
            return .failure(OpError(message: "Couldn't refresh “\(label)” (\(e)). Check your connection and try again — nothing was changed."))
        }
        guard let freshBlob = ClaudeRefresh.apply(fresh, to: targetBlob) else {
            return .failure(OpError(message: "Couldn't apply the refreshed token to “\(label)”."))
        }

        // 4. Persist the rotation first — the old refresh token is already void server-side.
        guard writeStash(label, freshBlob) else {
            return .failure(OpError(message: "Couldn't save the refreshed token for “\(label)” — not switching, so nothing is lost."))
        }
        idx.record(label: label, identity: idx.accounts[label].map {
            ClaudeIdentity(accountUUID: $0.uuid, email: $0.email, organizationName: $0.organizationName)
        } ?? ClaudeIdentity(accountUUID: "unknown"))

        // 5. Go live, and gate on the artifact.
        guard writeLive(freshBlob) else {
            return .failure(OpError(message: "Couldn't write the live Keychain slot — try again."))
        }
        writeCredFile(freshBlob)
        guard readLive() == freshBlob else {
            return .failure(OpError(message: "Live slot didn't update (Keychain readback mismatch)."))
        }
        idx.activeLabel = label
        saveIndex(idx)
        let who = idx.accounts[label]?.email ?? label
        return .success("Switched to “\(label)” (\(who)). Start a new `claude` session to use it.")
    }

    /// Delete a stash. Refuses the currently-active account (switch away first).
    @discardableResult
    public static func remove(_ label: String) -> Result<String, OpError> {
        var idx = loadIndex()
        if (idx.activeLabel ?? activeLabel()) == label {
            return .failure(OpError(message: "“\(label)” is the active account — switch to another first."))
        }
        guard deleteStash(label) else {
            return .failure(OpError(message: "Couldn't remove “\(label)”."))
        }
        idx.forget(label: label)
        saveIndex(idx)
        return .success("Removed “\(label)”.")
    }
}
