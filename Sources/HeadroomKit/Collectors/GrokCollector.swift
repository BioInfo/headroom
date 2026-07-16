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
        guard let token = await Self.resolveValidToken(authPath), !token.isEmpty else {
            return needsLogin()   // no token and no refresh path → run `grok` to authenticate.
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

    // MARK: - auth.json + OIDC refresh
    //
    // auth.json is `{ "https://auth.x.ai::<client_id>": { key, refresh_token, expires_at,
    // oidc_client_id, … } }`. `key` is the bearer, valid ~6h. The grok CLI only refreshes it
    // when you run `grok`, so between runs it goes stale and the meter breaks. We refresh it
    // ourselves from the refresh token (x.ai's standard OIDC endpoint) and write the result
    // back — x.ai ROTATES the refresh token, so persisting it keeps both us and the CLI working.

    struct Entry { let key: String; let refreshToken: String?; let expiresAt: String?; let clientId: String? }

    /// The single provider entry (first one carrying a non-empty `key`) + its dict key.
    static func readEntry(_ path: URL) -> (dictKey: String, entry: Entry)? {
        guard let bytes = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return nil }
        for (k, v) in obj {
            if let e = v as? [String: Any], let key = e["key"] as? String, !key.isEmpty {
                return (k, Entry(key: key, refreshToken: e["refresh_token"] as? String,
                                 expiresAt: e["expires_at"] as? String, clientId: e["oidc_client_id"] as? String))
            }
        }
        return nil
    }

    /// A currently-valid access token: the stored `key` while unexpired, else a fresh one minted
    /// from the refresh token and written back to auth.json. nil only if there's no entry at all.
    static func resolveValidToken(_ path: URL) async -> String? {
        guard let (dictKey, entry) = readEntry(path) else { return nil }
        if let exp = parseISO(entry.expiresAt), exp > Date().addingTimeInterval(120) { return entry.key }
        guard let rt = entry.refreshToken, let cid = entry.clientId,
              let fresh = await refresh(refreshToken: rt, clientId: cid) else {
            return entry.key   // no refresh path / refresh failed → try the stored key; a dead one 401s.
        }
        writeBack(path: path, dictKey: dictKey, fresh: fresh)
        return fresh.accessToken
    }

    struct Fresh { let accessToken: String; let refreshToken: String?; let expiresIn: Double? }

    /// POST the refresh grant to x.ai's OIDC token endpoint. nil on any failure.
    static func refresh(refreshToken: String, clientId: String) async -> Fresh? {
        func enc(_ s: String) -> String {
            let allowed = CharacterSet(charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
        }
        var req = URLRequest(url: URL(string: "https://auth.x.ai/oauth2/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "accept")
        req.httpBody = Data("grant_type=refresh_token&refresh_token=\(enc(refreshToken))&client_id=\(enc(clientId))".utf8)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let at = obj["access_token"] as? String else { return nil }
        return Fresh(accessToken: at, refreshToken: obj["refresh_token"] as? String,
                     expiresIn: obj["expires_in"] as? Double)
    }

    /// Persist the refreshed token back into auth.json, preserving every other field. Best-effort.
    static func writeBack(path: URL, dictKey: String, fresh: Fresh) {
        guard let bytes = try? Data(contentsOf: path),
              var obj = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              var entry = obj[dictKey] as? [String: Any] else { return }
        entry["key"] = fresh.accessToken
        if let rt = fresh.refreshToken { entry["refresh_token"] = rt }
        if let ein = fresh.expiresIn {
            let fmt = ISO8601DateFormatter(); fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            entry["expires_at"] = fmt.string(from: Date().addingTimeInterval(ein))
        }
        obj[dictKey] = entry
        guard let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? out.write(to: path, options: .atomic)
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
