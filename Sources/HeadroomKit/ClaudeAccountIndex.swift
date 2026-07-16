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

        public init(uuid: String, email: String? = nil,
                    organizationName: String? = nil, verifiedAt: Date? = nil) {
            self.uuid = uuid; self.email = email
            self.organizationName = organizationName; self.verifiedAt = verifiedAt
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

    public mutating func record(label: String, identity: ClaudeIdentity, at now: Date = Date()) {
        accounts[label] = Entry(uuid: identity.accountUUID,
                                email: identity.email,
                                organizationName: identity.organizationName,
                                verifiedAt: now)
    }

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
                    verifiedAt: (d["verifiedAt"] as? Double).map { Date(timeIntervalSince1970: $0) })
            }
        }
        return idx
    }
}
