import Foundation

/// What Headroom knows about each captured Claude account, keyed by the one thing that
/// survives token rotation: `account.uuid`.
///
/// The old design stored a single label in `~/.claude/.headroom-active-claude` and treated it
/// as truth. It isn't: `/login` rewrites the live slot without telling us, so the pointer
/// starts lying and the next capture-away files the live account under the wrong label —
/// which is exactly how a real machine ended up with a stash named "personal" holding the
/// business account (verified: identical `account.uuid` to the live slot).
///
/// Here the pointer is demoted to a *cache*. The index records which uuid each label holds,
/// so a capture-away can be routed by verified identity instead of by a claim, and the UI can
/// show the account's real email rather than a label nobody can check.
public struct ClaudeAccountIndex: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let uuid: String
        public var email: String?
        public var organizationName: String?
        /// When we last confirmed this label→uuid binding against the profile endpoint.
        public var verifiedAt: Date?
        /// Set when this stash's refresh token came back `invalid_grant` — the account has
        /// been signed out (or its token family was revoked) and the stash is dead.
        ///
        /// **This marker is load-bearing, not cosmetic.** A refresh token is single-use:
        /// presenting a rotated one is a *replay*, which is the documented trigger for OAuth
        /// replay detection. Without a sticky marker we would re-present the same dead token
        /// on every refresh tick — hammering Anthropic with something that looks exactly like
        /// an attack. One failure per stash, then never again until re-captured.
        public var signedOutAt: Date?
        /// Don't attempt a refresh again before this time. Set after a TRANSIENT failure
        /// (429, network, unexpected 5xx) so a stash whose token is expired isn't retried on
        /// every ~3-minute tick — which is how the refresh endpoint 429s us in the first place.
        /// A stash token lasts hours, so backing off tens of minutes costs nothing.
        public var refreshRetryAfter: Date?

        public init(uuid: String, email: String? = nil,
                    organizationName: String? = nil, verifiedAt: Date? = nil,
                    signedOutAt: Date? = nil, refreshRetryAfter: Date? = nil) {
            self.uuid = uuid; self.email = email
            self.organizationName = organizationName; self.verifiedAt = verifiedAt
            self.signedOutAt = signedOutAt; self.refreshRetryAfter = refreshRetryAfter
        }
    }

    /// label → what that stash holds.
    public var accounts: [String: Entry]
    /// The label we believe is live. A cache — always re-verify before acting destructively.
    public var activeLabel: String?

    public init(accounts: [String: Entry] = [:], activeLabel: String? = nil) {
        self.accounts = accounts; self.activeLabel = activeLabel
    }

    /// The label bound to a uuid, if any. This is the routing question capture-away asks:
    /// "the live slot really holds uuid X — which stash is X's?"
    public func label(forUUID uuid: String) -> String? {
        accounts.first { $0.value.uuid == uuid }?.key
    }

    /// Record a verified label→uuid binding. Clears any `signedOutAt` marker: we only get
    /// here from a live, working credential, which is proof the stash is good again.
    public mutating func record(label: String, identity: ClaudeIdentity, at now: Date = Date()) {
        accounts[label] = Entry(uuid: identity.accountUUID,
                                email: identity.email,
                                organizationName: identity.organizationName,
                                verifiedAt: now,
                                signedOutAt: nil,
                                refreshRetryAfter: nil)   // a live cred clears any backoff too
    }

    /// May we attempt to refresh this stash now? False while signed out (terminal) or inside a
    /// transient-failure backoff window. An unknown label is refreshable (no entry → no bar).
    public func canRefresh(_ label: String, now: Date = Date()) -> Bool {
        guard let e = accounts[label] else { return true }
        if e.signedOutAt != nil { return false }
        if let after = e.refreshRetryAfter, now < after { return false }
        return true
    }

    /// Back off after a transient refresh failure. Stubs an entry if needed (a shell-tool
    /// stash has none), same as `markSignedOut`.
    public mutating func backOffRefresh(label: String, until: Date) {
        var e = accounts[label] ?? Entry(uuid: "unknown")
        e.refreshRetryAfter = until
        accounts[label] = e
    }

    /// Clear a transient backoff after a successful refresh (or a no-longer-needed one).
    public mutating func clearRefreshBackoff(label: String) {
        guard var e = accounts[label] else { return }
        e.refreshRetryAfter = nil
        accounts[label] = e
    }

    /// Mark a stash dead after `invalid_grant`. Sticky — see `Entry.signedOutAt`.
    ///
    /// Creates a stub entry if the label isn't known yet: a stash captured by the old shell
    /// tool (or any pre-index install) has no index entry, and the marker MUST still stick, or
    /// the dead refresh token gets replayed on every tick — the exact abuse the marker
    /// prevents. `uuid: "unknown"` is fine; a later verified re-capture overwrites it via
    /// `record`.
    public mutating func markSignedOut(label: String, at now: Date = Date()) {
        var e = accounts[label] ?? Entry(uuid: "unknown")
        e.signedOutAt = now
        accounts[label] = e
    }

    public func isSignedOut(_ label: String) -> Bool { accounts[label]?.signedOutAt != nil }

    public mutating func forget(label: String) {
        accounts.removeValue(forKey: label)
        if activeLabel == label { activeLabel = nil }
    }

    // MARK: - codec (hand-rolled: Date/optional churn isn't worth a Codable dance here)

    public func serialized() -> [String: Any] {
        var out: [String: Any] = [:]
        var accts: [String: Any] = [:]
        for (label, e) in accounts {
            var d: [String: Any] = ["uuid": e.uuid]
            if let v = e.email { d["email"] = v }
            if let v = e.organizationName { d["organizationName"] = v }
            if let v = e.verifiedAt { d["verifiedAt"] = v.timeIntervalSince1970 }
            if let v = e.signedOutAt { d["signedOutAt"] = v.timeIntervalSince1970 }
            if let v = e.refreshRetryAfter { d["refreshRetryAfter"] = v.timeIntervalSince1970 }
            accts[label] = d
        }
        out["accounts"] = accts
        if let a = activeLabel { out["activeLabel"] = a }
        return out
    }

    public static func deserialize(_ obj: [String: Any]) -> ClaudeAccountIndex {
        var idx = ClaudeAccountIndex()
        idx.activeLabel = obj["activeLabel"] as? String
        if let accts = obj["accounts"] as? [String: Any] {
            for (label, raw) in accts {
                guard let d = raw as? [String: Any], let uuid = d["uuid"] as? String else { continue }
                idx.accounts[label] = Entry(
                    uuid: uuid,
                    email: d["email"] as? String,
                    organizationName: d["organizationName"] as? String,
                    verifiedAt: (d["verifiedAt"] as? Double).map { Date(timeIntervalSince1970: $0) },
                    signedOutAt: (d["signedOutAt"] as? Double).map { Date(timeIntervalSince1970: $0) },
                    refreshRetryAfter: (d["refreshRetryAfter"] as? Double).map { Date(timeIntervalSince1970: $0) })
            }
        }
        return idx
    }
}
