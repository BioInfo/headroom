import Foundation

/// Kimi (Moonshot) coding-plan headroom collector — paste-a-token, browser-free.
///
/// Kimi signs in with Google, and Google refuses OAuth inside an embedded webview (its
/// "disallowed_useragent" block, and the user-agent trick no longer defeats it — verified
/// 2026-06-14). So Headroom doesn't try: the usage RPC accepts the session JWT as a plain
/// `Authorization: Bearer` with no cookie (verified `credentials: "omit"` → 200), exactly
/// like the MiniMax/GLM key path. The user grabs the token once and pastes it:
///
///   at kimi.com (logged in) → DevTools console → copy(localStorage.access_token)
///
///   POST www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages
///        body {"scope":["FEATURE_CODING"]}   header authorization: Bearer <token>
///
/// The token is a ~30-day JWT, so a 401 maps to `.needsLogin` ("paste a fresh one"). Plan
/// name comes from MembershipService/GetSubscription → subscription.goods.title.
public struct KimiCollector: Collector {
    public let id = "kimi"
    public let displayName = "Kimi"
    public let cadence: RefreshCadence = .relaxed   // remote API call

    /// Keychain service for the pasted session token (Headroom-owned).
    public static let keyService = "Headroom-kimi-token"

    private let usagesURL = URL(string: "https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages")!
    private let subscriptionURL = URL(string: "https://www.kimi.com/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscription")!
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
            envNames: ["KIMI_TOKEN", "KIMI_ACCESS_TOKEN"],
            filePaths: [])
    }

    private func request(_ url: URL, body: String, token: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "connect-protocol-version")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = Data(body.utf8)
        return req
    }

    public func collect() async throws -> ProviderUsage {
        guard let token = resolveToken(), !token.isEmpty else { return needsLogin(plan: "Coding") }

        let (data, response) = try await session.data(
            for: request(usagesURL, body: #"{"scope":["FEATURE_CODING"]}"#, token: token))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { return needsLogin(plan: "Coding") }   // expired/invalid token → re-paste
        guard code == 200 else {
            return ProviderUsage(provider: id, displayName: displayName, status: .error)
        }
        let plan = (try? await fetchPlan(token)) ?? nil
        return Self.parse(data, id: id, displayName: displayName, plan: plan)
    }

    /// Plan label (best-effort; nil on any failure — the usage still renders without it).
    private func fetchPlan(_ token: String) async throws -> String? {
        let (data, response) = try await session.data(
            for: request(subscriptionURL, body: "{}", token: token))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONDecoder().decode(SubscriptionResponse.self, from: data))?
            .subscription?.goods?.title
    }

    // MARK: - parsing (split out so tests can hit it with the captured response)

    static func parse(_ data: Data, id: String, displayName: String, plan: String?) -> ProviderUsage {
        guard let resp = try? JSONDecoder().decode(UsagesResponse.self, from: data),
              let feat = resp.usages?.first(where: { $0.scope == "FEATURE_CODING" }) ?? resp.usages?.first else {
            return ProviderUsage(provider: id, displayName: displayName, status: .error)
        }
        return ProviderUsage(provider: id, displayName: displayName, plan: plan,
                             metrics: feat.metrics, status: .ok)
    }

    // MARK: - response shapes

    /// GetUsages: values are out of `limit:"100"`, i.e. already percentages. `limits[]`
    /// holds rolling sub-windows (the 5h, `window.duration` 300 min); `detail` at the
    /// feature level is the plan-period cap.
    struct UsagesResponse: Decodable {
        let usages: [FeatureUsage]?
    }
    struct FeatureUsage: Decodable {
        let scope: String?
        let detail: Detail?
        let limits: [Limit]?

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
            if let d = detail, let pct = d.usedPercent {
                out.append(Metric(label: "Plan window", percentUsed: pct, unit: .percent,
                                  resetAt: ClaudeCollector.parseISO(d.resetTime)))
            }
            return out
        }
    }
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
        let used: String?
        let resetTime: String?
        /// `used` is a string count out of 100, so it is the percent directly.
        var usedPercent: Double? { used.flatMap(Double.init) }
    }

    struct SubscriptionResponse: Decodable {
        let subscription: Subscription?
        struct Subscription: Decodable { let goods: Goods? }
        struct Goods: Decodable { let title: String? }
    }
}
