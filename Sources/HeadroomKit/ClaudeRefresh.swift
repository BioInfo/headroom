import Foundation

/// OAuth refresh for a stashed Claude account — the fix for the switch-logout.
///
/// ## Why this exists
/// Claude Code ROTATES its refresh token: each refresh mints a new one and voids the old.
/// (Proven from switch backups — the same account's refresh token changed across a refresh
/// boundary with no switch in between.) A stash is a frozen copy of a rotating credential,
/// so it goes void on its own, with no bug on our side. Writing that dead token back into
/// the live slot is what logged the account out: replaying a rotated refresh token is the
/// textbook trigger for OAuth refresh-token-replay detection, which revokes the whole family.
///
/// So: **never write a stale token into the live slot.** Refresh the target first, write the
/// FRESH pair, and persist the rotation back to the stash immediately — the same
/// refresh-and-write-back contract `GrokCollector` already uses for x.ai.
///
/// ## Endpoint
/// Anthropic MOVED this endpoint. `console.anthropic.com/v1/oauth/token` now 404s; the live
/// one is `platform.claude.com/v1/oauth/token`. We try the current URL first and fall back to
/// the legacy one, so a future migration degrades instead of breaking (and so this keeps
/// working on an older host that hasn't cut over).
public enum ClaudeRefresh {
    /// Claude Code's public OAuth client. Public clients embed this by design (no secret);
    /// it is not a credential. Undocumented, hence the endpoint fallback below.
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    public static let tokenURLs = [
        URL(string: "https://platform.claude.com/v1/oauth/token")!,   // current
        URL(string: "https://console.anthropic.com/v1/oauth/token")!, // legacy — 404s as of 2026-07
    ]

    public struct Fresh: Equatable, Sendable {
        public let accessToken: String
        /// Nil when the server chose not to rotate. Callers MUST keep the existing refresh
        /// token in that case rather than clearing it.
        public let refreshToken: String?
        public let expiresAt: Date?
    }

    public enum Failure: Error, Equatable, Sendable {
        case revoked           // 400 invalid_grant / 401 — this refresh token is dead. Terminal.
        case http(Int)
        case malformed
        case transport(String)
    }

    public typealias Fetcher = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static func request(refreshToken: String, url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(WebUserAgent.desktopSafari, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    static func parse(_ data: Data, now: Date = Date()) -> Fresh? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String, !access.isEmpty else { return nil }
        var expiry: Date?
        if let secs = obj["expires_in"] as? Double { expiry = now.addingTimeInterval(secs) }
        else if let ms = obj["expires_at"] as? Double { expiry = Date(timeIntervalSince1970: ms / 1000) }
        let rt = obj["refresh_token"] as? String
        return Fresh(accessToken: access,
                     refreshToken: (rt?.isEmpty ?? true) ? nil : rt,
                     expiresAt: expiry)
    }

    /// Exchange a refresh token for a fresh pair. Tries each endpoint in order; a 404 (the
    /// migrated URL) falls through to the next rather than being reported as failure.
    ///
    /// ⚠️ This ROTATES the token server-side. Whatever you do with the result, the old refresh
    /// token is void the moment this succeeds — so the caller MUST persist `Fresh` or the
    /// account is stranded. Never call this speculatively.
    public static func refresh(refreshToken: String,
                               now: Date = Date(),
                               fetcher: Fetcher? = nil) async -> Result<Fresh, Failure> {
        let send: Fetcher = fetcher ?? { try await URLSession.shared.data(for: $0) }
        var lastFailure: Failure = .transport("no endpoint attempted")

        for url in tokenURLs {
            do {
                let (data, resp) = try await send(request(refreshToken: refreshToken, url: url))
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                switch code {
                case 200..<300:
                    guard let fresh = parse(data, now: now) else { return .failure(.malformed) }
                    return .success(fresh)
                case 400, 401:
                    // invalid_grant — the token is void (rotated away, or the family was
                    // revoked by a replay). Terminal: another endpoint won't say otherwise.
                    return .failure(.revoked)
                case 404:
                    lastFailure = .http(404)   // migrated away — try the next URL
                    continue
                default:
                    lastFailure = .http(code)
                    continue
                }
            } catch {
                lastFailure = .transport(error.localizedDescription)
                continue
            }
        }
        return .failure(lastFailure)
    }

    /// Splice a fresh token pair into an existing credentials blob, preserving every other
    /// field. This MUST be a splice, not a rebuild: the blob also carries `mcpOAuth.*` entries
    /// (paperclip, bio-research plugins, …) and scopes/subscriptionType that we don't own and
    /// must not drop. Returns nil if the blob isn't the shape we expect.
    public static func apply(_ fresh: Fresh, to blob: String) -> String? {
        guard let data = blob.data(using: .utf8),
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var oauth = obj["claudeAiOauth"] as? [String: Any] else { return nil }

        oauth["accessToken"] = fresh.accessToken
        if let rt = fresh.refreshToken { oauth["refreshToken"] = rt }   // absent => server didn't rotate
        if let exp = fresh.expiresAt { oauth["expiresAt"] = exp.timeIntervalSince1970 * 1000 }
        obj["claudeAiOauth"] = oauth

        guard let out = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: out, encoding: .utf8) else { return nil }
        return s
    }
}
