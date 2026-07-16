import Foundation

/// Who does this Claude credential actually belong to?
///
/// The credential blob Claude Code stores carries NO identity — only tokens, expiry, scopes,
/// `subscriptionType` and `rateLimitTier` (verified by dumping every key on a live blob).
/// So a stash label is a *claim*, and the `~/.claude/.headroom-active-claude` pointer is a
/// document that goes stale the instant `/login` rewrites the live slot behind our back.
/// Trusting it is how a capture-away lands a live account into the wrong stash.
///
/// `GET /api/oauth/profile` is the missing fact: it returns `account.uuid` — stable across
/// token rotation, unlike anything in the blob — plus the email/org for display. Identity
/// comes from here; the pointer is demoted to a cache we verify, never a source of truth.
public struct ClaudeIdentity: Equatable, Sendable {
    public let accountUUID: String
    public let email: String?
    public let organizationName: String?
    public let rateLimitTier: String?

    public init(accountUUID: String, email: String? = nil,
                organizationName: String? = nil, rateLimitTier: String? = nil) {
        self.accountUUID = accountUUID
        self.email = email
        self.organizationName = organizationName
        self.rateLimitTier = rateLimitTier
    }

    /// A short, non-secret label for logs and diagnostics. Never includes a token.
    public func summary() -> String {
        let who = email ?? String(accountUUID.prefix(8)) + "…"
        return organizationName.map { "\(who) · \($0)" } ?? who
    }
}

public enum ClaudeProfile {
    public static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    /// Why a profile lookup failed. `unauthorized` is load-bearing and must never be conflated
    /// with `transport`: a dead token means "this credential is void", while a network blip
    /// means "we don't know". Callers gate destructive writes on knowing the difference.
    public enum Failure: Error, Equatable, Sendable {
        case unauthorized          // 401/403 — the access token is void
        case http(Int)
        case malformed
        case transport(String)
    }

    /// Injectable transport so tests never touch the network.
    public typealias Fetcher = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static func parse(_ data: Data) -> ClaudeIdentity? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = obj["account"] as? [String: Any],
              let uuid = account["uuid"] as? String, !uuid.isEmpty else { return nil }
        let org = obj["organization"] as? [String: Any]
        return ClaudeIdentity(
            accountUUID: uuid,
            email: account["email"] as? String,
            organizationName: org?["name"] as? String,
            rateLimitTier: org?["rate_limit_tier"] as? String)
    }

    /// Resolve the identity behind an access token. Read-only: it never rotates or mutates
    /// anything, so it is always safe to call on a live credential.
    public static func fetch(accessToken: String,
                            fetcher: Fetcher? = nil) async -> Result<ClaudeIdentity, Failure> {
        var req = URLRequest(url: profileURL)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue(WebUserAgent.desktopSafari, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        let send: Fetcher = fetcher ?? { try await URLSession.shared.data(for: $0) }
        do {
            let (data, resp) = try await send(req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 { return .failure(.unauthorized) }
            guard (200..<300).contains(code) else { return .failure(.http(code)) }
            guard let id = parse(data) else { return .failure(.malformed) }
            return .success(id)
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }
}
