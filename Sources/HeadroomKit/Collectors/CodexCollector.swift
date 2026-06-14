import Foundation

/// Codex (OpenAI / ChatGPT) subscription headroom collector.
///
/// Browser-free and LIVE. Reads the Codex OAuth token from `~/.codex/auth.json`
/// (`tokens.access_token`) — the canonical store both the CLI and the desktop app
/// use, so it works for every user — and hits the same endpoint the Codex app
/// itself calls:
///
///   GET https://chatgpt.com/backend-api/wham/usage     (Bearer <token>)
///
/// ("wham" is Codex's backend codename.) Response carries the current rate-limit
/// windows directly from the server, so the numbers match the app exactly — unlike
/// the old session-log read, which was only as fresh as the last CLI session and
/// went stale (resets in the past) when the user worked in the desktop app.
///
/// `rate_limit.primary_window` ≈ 5-hour (`limit_window_seconds` 18000),
/// `secondary_window` ≈ weekly (604800). Each: `used_percent` + `reset_at` (epoch
/// seconds). The token is read fresh each poll so the app/CLI owns refresh; on a
/// 401 we report `.stale`.
public struct CodexCollector: Collector {
    public let id = "codex"
    public let displayName = "Codex"

    private let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private let authPath: URL
    private let session: URLSession

    public init(authPath: URL? = nil, session: URLSession = .shared) {
        self.authPath = authPath
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/auth.json")
        self.session = session
    }

    public func collect() async throws -> ProviderUsage {
        guard let auth = Self.readAuth(authPath), let token = auth.accessToken,
              !token.isEmpty else {
            return needsLogin()   // not logged in → run `codex` (or the app) to sign in.
        }

        var req = URLRequest(url: usageURL)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        req.setValue("application/json", forHTTPHeaderField: "accept")
        if let acc = auth.accountId {   // optional, accepted; Bearer alone also works.
            req.setValue(acc, forHTTPHeaderField: "chatgpt-account-id")
        }

        let (data, response) = try await session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 {
            return ProviderUsage(provider: id, displayName: displayName, status: .stale)
        }
        guard code == 200 else {
            return ProviderUsage(provider: id, displayName: displayName, status: .error)
        }
        let resp = try JSONDecoder().decode(Response.self, from: data)
        return ProviderUsage(provider: id, displayName: displayName,
                             plan: resp.plan_type, metrics: resp.metrics, status: .ok)
    }

    // MARK: - auth.json

    struct Auth { let accessToken: String?; let accountId: String? }

    static func readAuth(_ path: URL) -> Auth? {
        guard let bytes = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any] else { return nil }
        return Auth(accessToken: tokens["access_token"] as? String,
                    accountId: tokens["account_id"] as? String)
    }

    // MARK: - response shape (chatgpt.com/backend-api/wham/usage)

    struct Response: Decodable {
        let plan_type: String?
        let rate_limit: RateLimit?

        var metrics: [Metric] {
            guard let rl = rate_limit else { return [] }
            return [
                rl.primary_window?.metric(label: "5h window"),
                rl.secondary_window?.metric(label: "Weekly"),
            ].compactMap { $0 }
        }
    }
    struct RateLimit: Decodable {
        let primary_window: Window?
        let secondary_window: Window?
    }
    struct Window: Decodable {
        let used_percent: Double?
        let reset_at: Double?              // epoch seconds
        let reset_after_seconds: Double?   // relative fallback
        let limit_window_seconds: Double?  // window length (primary ≈ 18000, secondary ≈ 604800)

        func metric(label: String) -> Metric? {
            guard let used_percent else { return nil }
            return Metric(label: label, percentUsed: used_percent, unit: .percent,
                          resetAt: resetDate, windowDuration: limit_window_seconds)
        }
        private var resetDate: Date? {
            if let reset_at { return Date(timeIntervalSince1970: reset_at) }
            if let reset_after_seconds { return Date().addingTimeInterval(reset_after_seconds) }
            return nil
        }
    }
}
