import Foundation

/// Grok (xAI SuperGrok / Grok Build) subscription headroom collector.
///
/// Browser-free and LIVE, the same shape as `CodexCollector`: read the Grok CLI's own
/// local OIDC token from `~/.grok/auth.json` and hit the endpoint the CLI itself polls
/// for its weekly credit meter (the one it logs as `billing: fetched credits config`):
///
///   GET https://cli-chat-proxy.grok.com/v1/billing?format=credits
///   Authorization: Bearer <oidc access token>
///   x-grok-client-version: <cli version>
///
/// `config.creditUsagePercent` is the weekly usage percent (0–100) against the
/// SuperGrok / Grok Build allowance; `config.currentPeriod` is the billing window
/// (`start`/`end`/`type`, e.g. `USAGE_PERIOD_TYPE_WEEKLY`). This is cleaner than the
/// gRPC-web + browser-cookie path other trackers use — a plain JSON GET with the local
/// bearer, no protobuf and no cookie import.
///
/// The token is read fresh each poll so the CLI owns refresh. On 401/403 (token) or 402
/// ("Grok Build usage balance exhausted" — you're capped for the window, still authed)
/// we report `.stale` and keep the last good reading. We never store, log, or commit the
/// token. auth.json holds one entry keyed by `https://auth.x.ai::<client_id>`, whose
/// `key` field is the bearer.
public struct GrokCollector: Collector {
    public let id = "grok"
    public let displayName = "Grok"

    private let usageURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    private let authPath: URL
    private let clientVersion: String
    private let session: URLSession

    public init(authPath: URL? = nil, clientVersion: String = "0.2.93",
                session: URLSession = .shared) {
        self.authPath = authPath
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".grok/auth.json")
        self.clientVersion = clientVersion
        self.session = session
    }

    public func collect() async throws -> ProviderUsage {
        guard let token = Self.readToken(authPath), !token.isEmpty else {
            return needsLogin()   // not signed in → run `grok` to authenticate.
        }

        var req = URLRequest(url: usageURL)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        req.setValue("application/json", forHTTPHeaderField: "accept")
        req.setValue(clientVersion, forHTTPHeaderField: "x-grok-client-version")

        let (data, response) = try await session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 401/403 = token expired/insufficient; 402 = balance exhausted (capped, still
        // authed). Either way keep the last good reading rather than flashing an error.
        if code == 401 || code == 402 || code == 403 {
            return ProviderUsage(provider: id, displayName: displayName, status: .stale)
        }
        guard code == 200 else {
            return ProviderUsage(provider: id, displayName: displayName, status: .error)
        }
        let resp = try JSONDecoder().decode(Response.self, from: data)
        return ProviderUsage(provider: id, displayName: displayName,
                             plan: resp.config?.subscriptionTier,
                             metrics: resp.config?.metrics ?? [], status: .ok)
    }

    // MARK: - auth.json (the OIDC bearer under the single `https://auth.x.ai::…` key)

    /// auth.json is `{ "https://auth.x.ai::<client_id>": { "key": <bearer>, … } }` — a
    /// single provider entry whose `key` is the access token. We match structurally (the
    /// first entry carrying a non-empty `key`) rather than hard-coding the client_id.
    static func readToken(_ path: URL) -> String? {
        guard let bytes = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        else { return nil }
        for (_, v) in obj {
            if let entry = v as? [String: Any],
               let key = entry["key"] as? String, !key.isEmpty { return key }
        }
        return nil
    }

    // MARK: - response shape (cli-chat-proxy.grok.com/v1/billing?format=credits)

    struct Response: Decodable { let config: Config? }

    struct Config: Decodable {
        let creditUsagePercent: Double?
        let currentPeriod: Period?
        let subscriptionTier: String?    // present in some responses; used as the plan label

        /// One weekly (or monthly) meter from `creditUsagePercent` over `currentPeriod`.
        var metrics: [Metric] {
            guard let pct = creditUsagePercent else { return [] }
            return [Metric(label: currentPeriod?.label ?? "Weekly",
                           percentUsed: pct, unit: .percent,
                           resetAt: currentPeriod?.resetAt,
                           windowDuration: currentPeriod?.duration)]
        }
    }

    struct Period: Decodable {
        let start: String?
        let end: String?
        let type: String?

        /// The window's name from its period type.
        var label: String {
            switch type {
            case "USAGE_PERIOD_TYPE_WEEKLY":  return "Weekly"
            case "USAGE_PERIOD_TYPE_MONTHLY": return "Monthly"
            case "USAGE_PERIOD_TYPE_DAILY":   return "Daily"
            default:                          return "Usage period"
            }
        }
        var resetAt: Date? { GrokCollector.parseISO(end) }
        /// Window length start→end (≈604800 for weekly) — drives even-burn pace projection.
        var duration: TimeInterval? {
            guard let s = GrokCollector.parseISO(start),
                  let e = GrokCollector.parseISO(end), e > s else { return nil }
            return e.timeIntervalSince(s)
        }
    }

    /// `start`/`end` carry microseconds + offset (`2026-07-12T13:44:34.109152+00:00`) →
    /// needs `.withFractionalSeconds`; plain ISO8601 is the fallback.
    static func parseISO(_ s: String?) -> Date? {
        guard let s else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }
        return ISO8601DateFormatter().date(from: s)
    }
}
