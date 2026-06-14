import Foundation

/// Claude (Anthropic) subscription headroom collector.
///
/// Browser-free. Uses the Claude Code CLI's own local OAuth token — the same
/// `sk-ant-oat01…` credential the CLI already keeps refreshed. Read from wherever
/// Claude Code stores it, so this works for every user, not just this machine:
///   1. `~/.claude/.credentials.json` (Linux, and many macOS setups) — top-level
///      `claudeAiOauth.accessToken`. Cross-platform, no Keychain prompt.
///   2. macOS login Keychain, service `Claude Code-credentials` — the macOS default.
/// That token reaches the official endpoint directly, no web login and no
/// Cloudflare challenge (api.anthropic.com doesn't gate API clients):
///
///   GET https://api.anthropic.com/api/oauth/usage
///   Authorization: Bearer sk-ant-oat01…
///
/// Response carries rolling-window utilization (`five_hour`, `seven_day`, the
/// per-model weekly windows) plus the extra-usage credit pool. `utilization` is
/// already a percent; `resets_at` is ISO-8601 with microseconds + offset.
///
/// The token is read fresh from the Keychain each poll, so the CLI owns refresh;
/// if it has expired and the CLI hasn't refreshed it, the call 401s and we report
/// `.stale`. We never store, log, or commit the token.
public struct ClaudeCollector: Collector {
    public let id = "claude"
    public let displayName = "Claude"

    private let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let credentialsPath: URL
    private let keychainService: String
    private let session: URLSession
    /// Off by default: Extra usage is a $ credit pool, not subscription headroom, and
    /// (as the highest reading) it hijacks the menu-bar glyph. Surfaced only when the
    /// user opts in via Settings. See docs/ROADMAP Phase 5.
    private let includeExtraUsage: Bool

    public init(credentialsPath: URL? = nil,
                keychainService: String = "Claude Code-credentials",
                includeExtraUsage: Bool = false,
                session: URLSession = .shared) {
        self.credentialsPath = credentialsPath
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/.credentials.json")
        self.keychainService = keychainService
        self.includeExtraUsage = includeExtraUsage
        self.session = session
    }

    public func collect() async throws -> ProviderUsage {
        guard let creds = readCreds(),
              let token = creds.accessToken, !token.isEmpty else {
            return needsLogin()   // CLI not logged in → run `claude` to authenticate.
        }

        var req = URLRequest(url: usageURL)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        req.setValue("application/json", forHTTPHeaderField: "accept")

        let (data, response) = try await session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 {
            // Token expired/insufficient; the CLI refreshes on next use.
            return ProviderUsage(provider: id, displayName: displayName,
                                 plan: creds.subscriptionType, status: .stale)
        }
        guard code == 200 else {
            return ProviderUsage(provider: id, displayName: displayName,
                                 plan: creds.subscriptionType, status: .error)
        }
        let usage = try JSONDecoder().decode(Usage.self, from: data)
        var metrics = usage.metrics
        if includeExtraUsage, let extra = usage.extraUsageMetric { metrics.append(extra) }
        return ProviderUsage(provider: id, displayName: displayName,
                             plan: creds.subscriptionType,
                             metrics: metrics, status: .ok)
    }

    // MARK: - credentials (file first, Keychain fallback)

    struct Creds { let accessToken: String?; let subscriptionType: String? }

    /// File-first (cross-platform), then macOS Keychain. Whichever Claude Code uses.
    func readCreds() -> Creds? {
        Self.credsFromFile(credentialsPath) ?? Self.credsFromKeychain(service: keychainService)
    }

    /// `~/.claude/.credentials.json` — the universal store (Linux + many macOS setups).
    static func credsFromFile(_ path: URL) -> Creds? {
        guard let bytes = try? Data(contentsOf: path) else { return nil }
        return creds(fromJSON: bytes)
    }

    /// macOS login Keychain via `/usr/bin/security` (the macOS default store).
    /// May prompt once to grant access; "Always Allow" persists it. No-op off macOS.
    static func credsFromKeychain(service: String) -> Creds? {
        #if os(macOS)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-w"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return creds(fromJSON: out.fileHandleForReading.readDataToEndOfFile())
        #else
        return nil
        #endif
    }

    /// Both stores hold the same blob: `{ "claudeAiOauth": { accessToken, subscriptionType, … } }`.
    private static func creds(fromJSON bytes: Data) -> Creds? {
        guard let obj = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any] else { return nil }
        return Creds(accessToken: oauth["accessToken"] as? String,
                     subscriptionType: oauth["subscriptionType"] as? String)
    }

    // MARK: - response shape (only the windows we render; unknown null siblings ignored)

    struct Usage: Decodable {
        let five_hour: Window?
        let seven_day: Window?
        let seven_day_opus: Window?
        let seven_day_sonnet: Window?
        let extra_usage: ExtraUsage?

        var metrics: [Metric] {
            let week: TimeInterval = 7 * 86400
            var m: [Metric] = []
            if let w = five_hour      { m.append(w.metric(label: "5h window", window: 5 * 3600)) }
            if let w = seven_day      { m.append(w.metric(label: "Weekly", window: week)) }
            if let w = seven_day_opus   { m.append(w.metric(label: "Weekly (Opus)", window: week)) }
            if let w = seven_day_sonnet { m.append(w.metric(label: "Weekly (Sonnet)", window: week)) }
            return m
        }

        /// The monthly pay-as-you-go credit pool, as a `.usd` metric. Opt-in only (it's
        /// a $ pool, not subscription headroom). nil unless enabled with a utilization.
        var extraUsageMetric: Metric? {
            guard let e = extra_usage, e.is_enabled == true, let pct = e.utilization else { return nil }
            return Metric(label: "Extra usage", used: e.used_credits,
                          limit: e.monthly_limit, percentUsed: pct, unit: .usd)
        }
    }

    struct Window: Decodable {
        let utilization: Double?
        let resets_at: String?
        func metric(label: String, window: TimeInterval) -> Metric {
            Metric(label: label, percentUsed: utilization, unit: .percent,
                   resetAt: ClaudeCollector.parseISO(resets_at), windowDuration: window)
        }
    }

    struct ExtraUsage: Decodable {
        let is_enabled: Bool?
        let monthly_limit: Double?
        let used_credits: Double?
        let utilization: Double?
    }

    /// `resets_at` carries fractional seconds + offset (e.g. `…00:00.377912+00:00`),
    /// which needs `.withFractionalSeconds`; plain ISO8601 returns nil for it.
    static func parseISO(_ s: String?) -> Date? {
        guard let s else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }
        return ISO8601DateFormatter().date(from: s)
    }
}
