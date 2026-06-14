import Foundation

/// MiniMax coding-plan (Token Plan) headroom collector.
///
/// Browser-free and LIVE. MiniMax's own usage endpoint accepts the coding-plan
/// subscription key (`sk-cp-…`) as a plain Bearer, so this is the Claude/Codex
/// pattern — resolve a local key, hit the official endpoint, decode:
///
///   GET https://api.minimax.io/v1/token_plan/remains    (Bearer <subscription key>)
///
/// Response carries `model_remains[]`, one entry per model class (`general` = the
/// text/coding plan, `video`, …). Each entry holds two windows directly from the
/// server — a 5-hour rolling interval and a weekly window — as `*_remaining_percent`
/// plus epoch-ms `start_time`/`end_time`. Headroom is a coding-quota gauge, so v1
/// surfaces the `general` model's two windows; the others are in the response if we
/// ever want them (see docs/PROVIDERS.md).
///
/// Key resolution (LocalKey): Headroom's paste-once keychain entry → `MINIMAX_API_KEY`
/// env → `~/.minimax-api-key`. No key → `.needsLogin` (paste one in Settings). A
/// `2049 invalid api key` body also maps to `.needsLogin`; other failures → `.error`.
public struct MiniMaxCollector: Collector {
    public let id = "minimax"
    public let displayName = "MiniMax"

    /// Keychain service for the user's pasted MiniMax key (Headroom-owned, never MiniMax's store).
    public static let keyService = "Headroom-minimax-key"

    private let usageURL = URL(string: "https://api.minimax.io/v1/token_plan/remains")!
    private let session: URLSession
    /// Override for tests; nil → resolve from local sources.
    private let keyOverride: String?

    public init(session: URLSession = .shared, key: String? = nil) {
        self.session = session
        self.keyOverride = key
    }

    private func resolveKey() -> String? {
        if let keyOverride { return keyOverride }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return LocalKey.resolve(
            storedService: Self.keyService,
            envNames: ["MINIMAX_API_KEY", "MINIMAX_KEY"],
            filePaths: [home.appendingPathComponent(".minimax-api-key")])
    }

    public func collect() async throws -> ProviderUsage {
        guard let key = resolveKey(), !key.isEmpty else { return needsLogin(plan: "Coding") }

        var req = URLRequest(url: usageURL)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            return ProviderUsage(provider: id, displayName: displayName, status: .error)
        }
        return Self.parse(data, id: id, displayName: displayName)
    }

    // MARK: - parsing (split out so tests can hit it with captured JSON)

    static func parse(_ data: Data, id: String, displayName: String) -> ProviderUsage {
        guard let resp = try? JSONDecoder().decode(Response.self, from: data) else {
            return ProviderUsage(provider: id, displayName: displayName, status: .error)
        }
        // MiniMax signals auth/business errors in the body with HTTP 200.
        if let sc = resp.base_resp?.status_code, sc != 0 {
            let status: Status = (sc == 2049) ? .needsLogin : .error   // 2049 = invalid api key
            return ProviderUsage(provider: id, displayName: displayName, plan: "Coding", status: status)
        }
        let general = resp.model_remains?.first { $0.model_name == "general" }
            ?? resp.model_remains?.first
        let metrics = general?.metrics ?? []
        return ProviderUsage(provider: id, displayName: displayName, plan: "Coding",
                             metrics: metrics, status: .ok)
    }

    // MARK: - response shape (api.minimax.io/v1/token_plan/remains)

    struct Response: Decodable {
        let model_remains: [ModelRemain]?
        let base_resp: BaseResp?
    }
    struct BaseResp: Decodable { let status_code: Int?; let status_msg: String? }

    struct ModelRemain: Decodable {
        let model_name: String?
        // 5-hour rolling interval
        let start_time: Double?                       // epoch ms
        let end_time: Double?                         // epoch ms — interval reset
        let current_interval_remaining_percent: Double?
        // weekly window
        let weekly_start_time: Double?
        let weekly_end_time: Double?                  // epoch ms — weekly reset
        let current_weekly_remaining_percent: Double?

        var metrics: [Metric] {
            [window(label: "5h window",
                    remaining: current_interval_remaining_percent,
                    startMs: start_time, endMs: end_time),
             window(label: "weekly",
                    remaining: current_weekly_remaining_percent,
                    startMs: weekly_start_time, endMs: weekly_end_time)]
                .compactMap { $0 }
        }

        private func window(label: String, remaining: Double?,
                            startMs: Double?, endMs: Double?) -> Metric? {
            guard let remaining else { return nil }
            let reset = dateFromEpochMillis(endMs)
            let dur: TimeInterval? = (startMs != nil && endMs != nil)
                ? (endMs! - startMs!) / 1000.0 : nil
            return Metric(label: label, percentUsed: 100 - remaining, unit: .percent,
                          resetAt: reset, windowDuration: dur)
        }
    }
}
