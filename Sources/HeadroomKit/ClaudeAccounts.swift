import Foundation

/// Read-only multi-account Claude reporting.
///
/// Claude Code keeps its OAuth creds in ONE slot: macOS login-Keychain item
/// "Claude Code-credentials". `/login` to a different account OVERWRITES it. We *read* that
/// slot to meter the live account, and let a user stash a copy of each account's blob under
/// its own Headroom-owned item ("Headroom-claude-acct-<label>") so each account gets its own
/// card.
///
/// ## We read Claude Code's credentials. We never write them. (1.6.2)
/// Switching accounts — copying a stash back into the live slot — was removed. Writing
/// another app's Keychain item silently rewrites that item's PARTITION LIST to the writing
/// binary's identity, evicting the owner; Claude Code then prompts for the login-keychain
/// password on every token read, roughly every 20 minutes, and it cannot be repaired without
/// the user's password. The full mechanism, the proof, and the recovery command are on
/// `switchTo`. Use `claude /login` to change accounts.
///
/// Writes to our own `Headroom-*` stashes are safe and are verified by reading them back
/// (gate on the artifact, not the exit code); the token value is never logged.
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

    /// The label of the account currently in the live slot, per the pointer file, or nil.
    public static func activeLabel() -> String? {
        guard let s = try? String(contentsOf: pointerURL, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func setPointer(_ label: String) {
        try? label.write(to: pointerURL, atomically: true, encoding: .utf8)
    }

    // NOTE: `writeCredFile` and `backupLive` were removed in 1.6.2 along with `switchTo`.
    // Both existed only to serve the live-slot write. `writeCredFile` in particular wrote
    // Claude Code's OWN `~/.claude/.credentials.json` — the same cross-app-write mistake as
    // the Keychain one, in file form. We read Claude Code's credentials; we never write them.

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

    // NOTE: there is deliberately no `writeLive`. Writing `Claude Code-credentials` evicts
    // Claude Code from that item's Keychain partition list and condemns the user to a
    // password prompt every ~20 minutes, unfixable without their keychain password. See the
    // long note on `switchTo`. We read the live slot; we never write it.
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
    /// ## REMOVED in 1.6.2 — and it must not come back. Read this before rewiring it.
    ///
    /// Switching required writing Claude Code's own `Claude Code-credentials` Keychain item.
    /// **Any write to another app's Keychain item silently rewrites that item's PARTITION
    /// LIST to the writing binary's identity, evicting the owner.** Proven directly:
    ///
    /// ```
    /// partitions BEFORE:  ["apple-tool:"]
    /// SecItemUpdate -> OK
    /// partitions AFTER:   ["cdhash:<the writer>"]     // the previous entry is GONE
    /// ```
    ///
    /// So every switch kicked `teamid:Q6L2SF6YDW` (Claude Code) out and left
    /// `teamid:83XUJJQQL9` (us) behind. Claude Code then had to prompt for the login-keychain
    /// password on **every** token read — about every 20 minutes, forever. It is not
    /// self-healing and we cannot repair it silently: rewriting a partition list is itself a
    /// CHANGE-ACL operation, whose ACL is an empty trusted list, so it always demands the
    /// user's keychain password. There is no unattended fix, which is why the feature is gone
    /// rather than patched.
    ///
    /// The old ACL/trusted-app reasoning was not wrong, it was just aimed at the wrong gate —
    /// `SecItemUpdate` and `security add-generic-password -U` both *do* preserve the
    /// trusted-app ACL (verified). The partition list is a second, independent gate, and that
    /// is the one a write destroys.
    ///
    /// Recovery for anyone already hit (one prompt, then permanent — pin the **team**, not a
    /// cdhash, or Claude Code's next auto-update breaks it again):
    /// ```
    /// security set-generic-password-partition-list \
    ///   -S "apple-tool:,teamid:Q6L2SF6YDW,teamid:83XUJJQQL9" \
    ///   -s "Claude Code-credentials" -a "$USER"
    /// ```
    ///
    /// Reading the live slot stays fine — reads touch nothing. `capture`/`remove` are fine too:
    /// they only ever write `Headroom-claude-acct-*`, items we own. To change accounts, use
    /// Claude Code's own `/login`; it owns that credential and rotates it out from under any
    /// copy we could hold anyway (see `ClaudeRefresh`).
    ///
    /// Prior art we should have believed: CodexBar (60 providers) refuses to own this surface
    /// for the same reason.
    @available(*, unavailable, message: "Removed in 1.6.2: writing Claude Code's Keychain item evicts it from the item's partition list, causing permanent password prompts with no silent repair. Use `claude /login` to change accounts.")
    public static func switchTo(_ label: String) async -> Result<String, OpError> {
        .failure(OpError(message: "Switching accounts was removed in 1.6.2 — use `claude /login`."))
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
