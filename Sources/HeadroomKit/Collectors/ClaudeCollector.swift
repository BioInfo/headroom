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

    // MARK: - credentials (expiry-aware: file fast-path, Keychain fallback)

    struct Creds {
        let accessToken: String?
        let subscriptionType: String?
        let expiresAt: Date?

        /// A non-empty token that hasn't passed its expiry (with a small skew so a
        /// token about to lapse isn't picked only to 401 on the next call). An
        /// unknown expiry is treated as usable (best-effort) rather than discarded.
        func isUsable(now: Date = Date()) -> Bool {
            guard let t = accessToken, !t.isEmpty else { return false }
            guard let exp = expiresAt else { return true }
            return exp > now.addingTimeInterval(120)
        }
    }

    /// File first as a fast path, but never trust an EXPIRED file token over a live
    /// Keychain one. On macOS the CLI keeps its authoritative token in the Keychain
    /// and refreshes it there; a `~/.claude/.credentials.json` written at login can
    /// then drift stale (the logout/login failure mode). So: use the file token only
    /// while it's still usable; otherwise consult the Keychain and take whichever
    /// token is valid / expires later.
    func readCreds() -> Creds? {
        let file = Self.credsFromFile(credentialsPath)
        if let file, file.isUsable() { return file }          // fast path, no Keychain touch
        let keychain = Self.credsFromKeychain(service: keychainService)
        return Self.fresher(file, keychain)
    }

    /// Pick the better of two credential blobs: prefer the one whose token expires
    /// later (a known future expiry beats an unknown one). Used only after the file
    /// fast path misses, so this is where a stale file yields to a fresh Keychain.
    static func fresher(_ a: Creds?, _ b: Creds?) -> Creds? {
        switch (a, b) {
        case (nil, nil): return nil
        case (let x?, nil): return x
        case (nil, let y?): return y
        case (let x?, let y?):
            let ex = x.expiresAt ?? .distantPast
            let ey = y.expiresAt ?? .distantPast
            return ey > ex ? y : x
        }
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

    /// Both stores hold the same blob: `{ "claudeAiOauth": { accessToken, subscriptionType, expiresAt, … } }`.
    /// `expiresAt` is epoch milliseconds; we keep it so an expired token can't shadow a live one.
    static func creds(fromJSON bytes: Data) -> Creds? {
        guard let obj = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any] else { return nil }
        let expiresAt = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return Creds(accessToken: oauth["accessToken"] as? String,
                     subscriptionType: oauth["subscriptionType"] as? String,
                     expiresAt: expiresAt)
    }

    // MARK: - response shape (only the windows we render; unknown null siblings ignored)

    /// Two shapes coexist while Anthropic migrates the endpoint:
    ///   • NEW (canonical): a `limits` array — one entry per active limit, each with a
    ///     `kind` (`session` = 5h, `weekly_all` = overall weekly, `weekly_scoped` = a
    ///     per-model weekly cap carrying `scope.model.display_name`), a `percent`, and a
    ///     `resets_at`. The per-model weekly (e.g. the Opus/Fable weekly cap on Max — the
    ///     one you're most likely to hit) lives ONLY here now.
    ///   • OLD (back-compat): flat `five_hour` / `seven_day` / `seven_day_opus` /
    ///     `seven_day_sonnet` sibling objects. `seven_day_opus`/`seven_day_sonnet` now come
    ///     back null on current accounts — the scoped weekly moved into `limits`.
    /// We prefer `limits` whenever it's present and non-empty; otherwise fall back to the
    /// flat fields. `extra_usage` is a separate flat field in both shapes.
    struct Usage: Decodable {
        let limits: [Limit]?
        let five_hour: Window?
        let seven_day: Window?
        let seven_day_opus: Window?
        let seven_day_sonnet: Window?
        let extra_usage: ExtraUsage?

        /// The window meters. `extra_usage` is intentionally NOT here — it's surfaced
        /// separately via `extraUsageMetric` (opt-in; a $ pool, not subscription headroom).
        var metrics: [Metric] {
            (limits?.isEmpty == false) ? limitMetrics : flatMetrics
        }

        /// New-shape mapping: one Metric per known limit, in a stable session→weekly order.
        private var limitMetrics: [Metric] {
            let week: TimeInterval = 7 * 86400
            return (limits ?? [])
                .sorted { $0.rank < $1.rank }
                .compactMap { l -> Metric? in
                    guard let pct = l.percent else { return nil }
                    let reset = ClaudeCollector.parseISO(l.resets_at)
                    switch l.kind {
                    case "session":
                        return Metric(label: "5h window", percentUsed: pct, unit: .percent,
                                      resetAt: reset, windowDuration: 5 * 3600)
                    case "weekly_all":
                        return Metric(label: "Weekly", percentUsed: pct, unit: .percent,
                                      resetAt: reset, windowDuration: week)
                    case "weekly_scoped":
                        let model = l.scope?.model?.display_name ?? "model"
                        return Metric(label: "Weekly (\(model))", percentUsed: pct, unit: .percent,
                                      resetAt: reset, windowDuration: week)
                    default:
                        return nil   // unknown kind — don't render a mystery meter
                    }
                }
        }

        /// Old-shape mapping (kept for accounts still on the flat fields, and for the
        /// captured-fixture tests). `seven_day_opus`/`seven_day_sonnet` are usually null now.
        private var flatMetrics: [Metric] {
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

    /// One entry in the new `limits` array. `kind` is the discriminator
    /// (`session` / `weekly_all` / `weekly_scoped`); `percent` is already 0...100;
    /// `scope.model.display_name` names the model a `weekly_scoped` cap applies to.
    /// `is_active` / `severity` are carried by the API but not yet rendered (percent
    /// already drives the tier color and threshold alerts).
    struct Limit: Decodable {
        let kind: String?
        let group: String?
        let percent: Double?
        let resets_at: String?
        let scope: LimitScope?

        /// Stable display order: 5h first, then overall weekly, then per-model weekly.
        var rank: Int {
            switch kind {
            case "session": return 0
            case "weekly_all": return 1
            case "weekly_scoped": return 2
            default: return 3
            }
        }
    }

    struct LimitScope: Decodable { let model: LimitModel? }
    struct LimitModel: Decodable { let display_name: String? }

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
