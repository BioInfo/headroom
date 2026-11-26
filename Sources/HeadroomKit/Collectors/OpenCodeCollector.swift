import Foundation

/// OpenCode Go subscription headroom collector — API key, no browser.
///
///   GET https://opencode.ai/zen/go/v1/usage     header  Authorization: Bearer <OpenCode key>
///
/// Returns three dollar-allowance windows, each already a percent:
///   `{"usage":{"rolling":{"status":"ok","percent":9,"resetsAt":"…Z"},
///              "weekly":{…}, "monthly":{…}}}`
/// `rolling` is the 5-hour window. The endpoint is undocumented (verified live 2026-11-26;
/// `/zen/v1/usage` and `/zen/go/v1/balance` 404), so a shape change lands as `.error`,
/// never as an empty-but-ok card.
///
/// The key is the same OpenCode API key the `opencode` CLI and Zen routes use
/// (opencode.ai → workspace → API keys).
public struct OpenCodeCollector: Collector {
    public let id = "opencode"
    public let displayName = "OpenCode Go"
    public let cadence: RefreshCadence = .relaxed   // remote API call

    /// Keychain service for the pasted API key (Headroom-owned).
    public static let keyService = "Headroom-opencode-key"

    private let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!
    private let session: URLSession
    private let tokenOverride: String?

    public init(session: URLSession = .shared, token: String? = nil) {
        self.session = session
        self.tokenOverride = token
    }

    private func resolveToken() -> String? {
        if let tokenOverride { return tokenOverride }
        return LocalKey.resolve(storedService: Self.keyService,
                                envNames: ["OPENCODE_API_KEY", "OPENCODE_GO_API_KEY"],
                                filePaths: [])
    }

    public func collect() async throws -> ProviderUsage {
        guard let key = resolveToken(), !key.isEmpty else { return needsLogin(plan: "Go") }
        var req = URLRequest(url: usageURL)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { return needsLogin(plan: "Go") }
        guard code == 200 else {
            return ProviderUsage(provider: id, displayName: displayName, plan: "Go", status: .error)
        }
        return Self.parse(data, id: id, displayName: displayName)
    }

    static func parse(_ data: Data, id: String, displayName: String) -> ProviderUsage {
        guard let resp = try? JSONDecoder().decode(Response.self, from: data),
              let u = resp.usage else {
            return ProviderUsage(provider: id, displayName: displayName, plan: "Go", status: .error)
        }
        var metrics: [Metric] = []
        func add(_ w: Window?, _ label: String, _ dur: TimeInterval) {
            guard let w, let pct = w.percent else { return }
            metrics.append(Metric(label: label, percentUsed: pct, unit: .percent,
                                  resetAt: ClaudeCollector.parseISO(w.resetsAt), windowDuration: dur))
        }
        add(u.rolling, "5h window", 5 * 3600)
        add(u.weekly, "Weekly", 7 * 86400)
        add(u.monthly, "Monthly", 30 * 86400)
        guard !metrics.isEmpty else {
            return ProviderUsage(provider: id, displayName: displayName, plan: "Go", status: .error)
        }
        return ProviderUsage(provider: id, displayName: displayName, plan: "Go",
                             metrics: metrics, status: .ok)
    }

    struct Response: Decodable { let usage: Usage? }
    struct Usage: Decodable { let rolling: Window?; let weekly: Window?; let monthly: Window? }
    struct Window: Decodable { let status: String?; let percent: Double?; let resetsAt: String? }
}
