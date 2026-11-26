import Foundation

/// Kimi (Moonshot) coding-plan headroom collector — API key, no browser, no expiry.
///
/// HISTORY, because the previous design failed in a way worth not repeating (2026-08-27):
/// this used to read the web app's session JWT out of `localStorage.access_token`, pasted by
/// hand. That token is a ~30-DAY credential. It expired on 2026-08-14 and the meter simply
/// stopped, because a paste-once secret with a fixed lifetime is a scheduled outage.
///
/// The coding plan's own API key reads the same numbers and does not expire:
///
///   GET https://api.kimi.com/coding/v1/usages     header  Authorization: Bearer sk-...
///
/// The response confirms the path in-band — `authentication.method == "METHOD_API_KEY"`,
/// `scope == "FEATURE_CODING"` — so the collector is not inferring which road it drove on.
/// `limits[]` holds the rolling 5h sub-window; the top-level `usage` is the plan-period cap.
/// Both are counts out of `limit:"100"`, i.e. already percentages.
///
/// Plan label comes from `/coding/v1/me` → `user_level_name` ("Allegretto"), replacing the
/// MembershipService RPC that only the web session could call.
///
/// The key is the same one that drives `cki` / the gateway's `kimi-latest` route: get it from
/// kimi.com → Code → API keys. A 401 still maps to `.needsLogin` (revoked or wrong key), but
/// it no longer arrives on a timer.
public struct KimiCollector: Collector {
    public let id = "kimi"
    public let displayName = "Kimi"
    public let cadence: RefreshCadence = .relaxed   // remote API call

    /// Keychain service for the pasted API key (Headroom-owned).
    /// Renamed from `Headroom-kimi-token` when the session-JWT path was retired — the old
    /// item held a different KIND of secret, so reusing the name would have let a stale JWT
    /// masquerade as a key.
    public static let keyService = "Headroom-kimi-key"

    private let usagesURL = URL(string: "https://api.kimi.com/coding/v1/usages")!
    private let meURL = URL(string: "https://api.kimi.com/coding/v1/me")!
    private let session: URLSession
    private let tokenOverride: String?

    public init(session: URLSession = .shared, token: String? = nil) {
        self.session = session
        self.tokenOverride = token
    }

    private func resolveToken() -> String? {
        if let tokenOverride { return tokenOverride }
        return LocalKey.resolve(
            storedService: Self.keyService,
            envNames: ["KIMI_API_KEY", "MOONSHOT_API_KEY", "KIMI_TOKEN"],
            filePaths: [])
    }

    private func request(_ url: URL, key: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return req
    }

    public func collect() async throws -> ProviderUsage {
        guard let key = resolveToken(), !key.isEmpty else { return needsLogin(plan: "Coding") }

        let (data, response) = try await session.data(for: request(usagesURL, key: key))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { return needsLogin(plan: "Coding") }   // revoked / wrong key
        guard code == 200 else {
            return ProviderUsage(provider: id, displayName: displayName, status: .error)
        }
        let plan = (try? await fetchPlan(key)) ?? nil
        return Self.parse(data, id: id, displayName: displayName, plan: plan)
    }

    /// Plan label (best-effort; nil on any failure — the usage still renders without it).
    private func fetchPlan(_ key: String) async throws -> String? {
        let (data, response) = try await session.data(for: request(meURL, key: key))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONDecoder().decode(MeResponse.self, from: data))?.userLevelName
    }

    // MARK: - parsing (split out so tests can hit it with the captured response)

    static func parse(_ data: Data, id: String, displayName: String, plan: String?) -> ProviderUsage {
        guard let resp = try? JSONDecoder().decode(UsagesResponse.self, from: data) else {
            return ProviderUsage(provider: id, displayName: displayName, status: .error)
        }
        let metrics = resp.metrics
        // No readable meter is an ERROR, never an empty-but-ok card. An absent reading is
        // not a good reading.
        guard !metrics.isEmpty else {
            return ProviderUsage(provider: id, displayName: displayName, status: .error)
        }
        return ProviderUsage(provider: id, displayName: displayName, plan: plan,
                             metrics: metrics, status: .ok)
    }

    // MARK: - response shapes

    /// `GET /coding/v1/usages`. Flat, unlike the old billing RPC's `usages[]` envelope.
    struct UsagesResponse: Decodable {
        let usage: Detail?          // plan-period cap
        let limits: [Limit]?        // rolling sub-windows (the 5h)
        let authentication: Authentication?

        var metrics: [Metric] {
            var out: [Metric] = []
            for lim in (limits ?? []) {
                guard let d = lim.detail, let pct = d.usedPercent else { continue }
                let dur = lim.window?.seconds
                let label = (dur == 18000) ? "5h window"
                          : (dur.map { "\(Int($0 / 3600))h window" } ?? "window")
                out.append(Metric(label: label, percentUsed: pct, unit: .percent,
                                  resetAt: ClaudeCollector.parseISO(d.resetTime), windowDuration: dur))
            }
            if let d = usage, let pct = d.usedPercent {
                out.append(Metric(label: "Plan window", percentUsed: pct, unit: .percent,
                                  resetAt: ClaudeCollector.parseISO(d.resetTime)))
            }
            return out
        }
    }
    struct Authentication: Decodable { let method: String?; let scope: String? }
    struct Limit: Decodable { let window: Window?; let detail: Detail? }
    struct Window: Decodable {
        let duration: Double?
        let timeUnit: String?
        var seconds: TimeInterval? {
            guard let duration else { return nil }
            switch timeUnit {
            case "TIME_UNIT_SECOND": return duration
            case "TIME_UNIT_MINUTE": return duration * 60
            case "TIME_UNIT_HOUR":   return duration * 3600
            case "TIME_UNIT_DAY":    return duration * 86400
            default:                  return duration * 60   // server uses minutes for the 5h window
            }
        }
    }
    struct Detail: Decodable {
        let limit: String?
        let used: String?
        let remaining: String?
        let resetTime: String?
        /// `used` is a string count out of 100, so it is the percent directly. At zero usage
        /// the server omits `used` and sends only `remaining` (seen 2026-09-24), so derive it
        /// from `limit - remaining` rather than dropping the window.
        var usedPercent: Double? {
            if let u = used.flatMap(Double.init) { return u }
            guard let r = remaining.flatMap(Double.init) else { return nil }
            let l = limit.flatMap(Double.init) ?? 100
            guard l > 0 else { return nil }
            return (l - r) / l * 100
        }
    }

    /// `GET /coding/v1/me` — only the plan label is used.
    struct MeResponse: Decodable {
        let userLevelName: String?
        enum CodingKeys: String, CodingKey { case userLevelName = "user_level_name" }
    }
}
