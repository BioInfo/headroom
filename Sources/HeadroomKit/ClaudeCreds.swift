import Foundation

/// Validates and summarizes a Claude Code OAuth credentials blob — the pure, testable
/// core behind Headroom's in-app account switching (`ClaudeAccounts`). It is the Swift
/// port of the shell `describe_blob` in the old `claude-switch` tool: given the raw JSON
/// a stash or the live Keychain slot holds, decide whether it's a real creds blob, when
/// its access token expires, and render a one-line human summary (never the token).
///
/// Both this and `ClaudeCollector.creds(fromJSON:)` read the SAME shape —
/// `{ "claudeAiOauth": { accessToken, refreshToken, subscriptionType, expiresAt } }` —
/// where `expiresAt` is epoch **milliseconds**. This type additionally decodes the access
/// token's JWT `exp` as a fallback when `expiresAt` is absent, and carries `refreshToken`,
/// because switching must never silently stash a blob that can't refresh.
///
/// No Keychain, no file I/O, no network — so it is fully unit-testable.
public struct ClaudeCreds: Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let subscriptionType: String?
    /// Access-token expiry, from `expiresAt` (ms) if present, else the JWT `exp` claim.
    public let expiresAt: Date?

    public var hasRefresh: Bool { !(refreshToken ?? "").isEmpty }

    /// Parse a raw blob. Returns nil if it isn't JSON, lacks `claudeAiOauth`, or has no
    /// non-empty `accessToken` — i.e. anything that isn't a usable creds blob.
    public static func parse(_ blob: String) -> ClaudeCreds? {
        guard let data = blob.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any] else { return nil }
        guard let access = (oauth["accessToken"] as? String), !access.isEmpty else { return nil }

        let refresh = (oauth["refreshToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let plan = (oauth["subscriptionType"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        // `expiresAt` is epoch-ms in the blob; JSON may hand it back as Double or Int.
        let expMs: Double? = (oauth["expiresAt"] as? Double)
            ?? (oauth["expiresAt"] as? Int).map(Double.init)
        let expiry = expMs.map { Date(timeIntervalSince1970: $0 / 1000) }
            ?? Self.jwtExpiry(access)

        return ClaudeCreds(accessToken: access, refreshToken: refresh,
                           subscriptionType: plan, expiresAt: expiry)
    }

    /// A non-empty token that hasn't passed its expiry (with a small skew so a token about
    /// to lapse isn't treated as good and then 401s). Unknown expiry → usable (best-effort),
    /// matching `ClaudeCollector.Creds.isUsable`.
    public func isUsable(now: Date = Date(), skew: TimeInterval = 120) -> Bool {
        guard let exp = expiresAt else { return true }
        return exp > now.addingTimeInterval(skew)
    }

    /// One-line, secret-free summary for status/switch output, e.g.
    /// `plan=max access_exp=2026-07-16 13:44 valid (312m left) refresh=yes`.
    public func summary(now: Date = Date()) -> String {
        let plan = subscriptionType ?? "unknown"
        guard let exp = expiresAt else {
            return "plan=\(plan) access_exp=unknown refresh=\(hasRefresh ? "yes" : "NO")"
        }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        let mins = Int(exp.timeIntervalSince(now) / 60)
        let state = mins > 0 ? "valid (\(mins)m left)" : "EXPIRED (\(-mins)m ago)"
        return "plan=\(plan) access_exp=\(df.string(from: exp)) \(state) refresh=\(hasRefresh ? "yes" : "NO")"
    }

    // MARK: - JWT exp fallback

    /// The `exp` (seconds since epoch) from a JWT access token's payload segment, or nil.
    /// Best-effort: any malformed segment yields nil rather than throwing.
    static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3, let payload = base64urlDecode(String(parts[1])),
              let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        let exp = (obj["exp"] as? Double) ?? (obj["exp"] as? Int).map(Double.init)
        return exp.map { Date(timeIntervalSince1970: $0) }
    }

    /// Decode a base64url segment (no padding, `-_` alphabet) to Data.
    static func base64urlDecode(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+")
                 .replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b.append("=") }
        return Data(base64Encoded: b)
    }
}
