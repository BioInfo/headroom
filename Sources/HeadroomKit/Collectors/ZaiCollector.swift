import Foundation
import WebKit

/// GLM / z.ai coding-plan collector.
///
/// Mechanism (captured + proven live, see docs/PROVIDERS.md):
/// a persistent WKWebView holds the logged-in z.ai session. We `evaluateJavaScript`
/// a function that reads the Bearer JWT + org/project ids from the page's localStorage
/// and replays `GET api.z.ai/api/monitor/usage/quota/limit`. The token never leaves the
/// webview. Response carries TIME_LIMIT (prompt window) + TOKENS_LIMIT, each with a
/// `nextResetTime` in epoch ms.
@MainActor
public final class ZaiCollector: NSObject, Collector {
    public let id = "zai"
    public let displayName = "GLM (z.ai)"
    public let cadence: RefreshCadence = .relaxed   // drives a WKWebView; poll gently

    private let usagePageURL = URL(string: "https://z.ai/manage-apikey/coding-plan/personal/usage")!
    private let quotaURL = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!
    private let webView: WKWebView

    /// Keychain service for the user's pasted GLM key (Headroom-owned, never z.ai's store).
    public static let keyService = "Headroom-zai-key"

    /// Local key sources tried before any browser path (z.ai's quota endpoint accepts
    /// the coding-plan key as a plain Bearer — see docs/PROVIDERS.md).
    private func resolveKey() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return LocalKey.resolve(
            storedService: Self.keyService,
            envNames: ["ZHIPUAI_API_KEY", "Z_AI_API_KEY", "GLM_API_KEY"],
            filePaths: [home.appendingPathComponent(".z-ai-api-key")])
    }

    public override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()   // persists cookies + localStorage across launches
        self.webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        // z.ai signs in via Google OAuth, which refuses embedded webviews; a desktop
        // Safari UA lets the login proceed. (The local-key path skips the webview entirely.)
        self.webView.customUserAgent = WebUserAgent.desktopSafari
        self.webView.navigationDelegate = self
    }

    // The exact payload proven in the DevTools spike, as a function BODY for
    // callAsyncJavaScript (which awaits the async work and resolves the promise;
    // plain evaluateJavaScript would hand back an unresolved Promise).
    private static let probeJS = """
    const token = localStorage.getItem("z-ai-open-platform-token-production");
    const org   = localStorage.getItem("Bigmodel-Organization");
    const proj  = localStorage.getItem("Bigmodel-Project");
    if (!token) return JSON.stringify({ ok:false, reason:"no-session" });
    try {
      const r = await fetch("https://api.z.ai/api/monitor/usage/quota/limit", {
        headers: { "authorization":"Bearer "+token, "bigmodel-organization":org||"",
                   "bigmodel-project":proj||"", "accept":"application/json" }
      });
      const j = await r.json();
      return JSON.stringify({ ok:true, status:r.status, level:j?.data?.level,
        limits:(j?.data?.limits||[]).map(l => ({ type:l.type, usage:l.usage,
          remaining:l.remaining, percentage:l.percentage, nextResetTime:l.nextResetTime })) });
    } catch (e) { return JSON.stringify({ ok:false, reason:String(e) }); }
    """

    public func collect() async throws -> ProviderUsage {
        // Browser-free path first: a local key → direct Bearer call, no webview.
        if let key = resolveKey(), let usage = try? await collectViaKey(key) {
            return usage
        }
        // Fallback: WKWebView session replay (user logs in once).
        return try await collectViaWebView()
    }

    /// Direct call with the local coding-plan key as Bearer. Returns nil on any
    /// failure so `collect()` falls back to the webview path.
    private func collectViaKey(_ key: String) async throws -> ProviderUsage? {
        var req = URLRequest(url: quotaURL)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        req.setValue("application/json", forHTTPHeaderField: "accept")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let resp = try JSONDecoder().decode(QuotaResponse.self, from: data)
        guard let limits = resp.data?.limits else { return nil }
        let metrics = limits.compactMap { $0.asMetric }
        guard !metrics.isEmpty else { return nil }
        return ProviderUsage(provider: id, displayName: displayName,
                             plan: resp.data?.level, metrics: metrics, status: .ok)
    }

    private func collectViaWebView() async throws -> ProviderUsage {
        try await loadUsagePage()
        guard let raw = try await evaluateString(Self.probeJS),
              let data = raw.data(using: .utf8) else {
            return ProviderUsage(provider: id, displayName: displayName, status: .error)
        }
        let probe = try JSONDecoder().decode(Probe.self, from: data)
        guard probe.ok else {
            return probe.reason == "no-session"
                ? needsLogin()
                : ProviderUsage(provider: id, displayName: displayName, status: .error)
        }
        let metrics = (probe.limits ?? []).compactMap { $0.asMetric }
        return ProviderUsage(provider: id, displayName: displayName, plan: probe.level,
                             metrics: metrics, status: .ok)
    }

    /// The WKWebView usable for an in-app login window when there's no session.
    public var loginWebView: WKWebView { webView }
    public func startLogin() { webView.load(URLRequest(url: usagePageURL)) }

    // MARK: - decoding

    /// Raw quota endpoint response (direct Bearer call): `{ data: { level, limits } }`.
    /// `limits` reuse the same `Limit` fields as the webview probe.
    private struct QuotaResponse: Decodable {
        let data: QuotaData?
    }
    private struct QuotaData: Decodable {
        let level: String?
        let limits: [Limit]?
    }

    private struct Probe: Decodable {
        let ok: Bool
        let reason: String?
        let level: String?
        let limits: [Limit]?
    }
    private struct Limit: Decodable {
        let type: String
        let usage: Double?
        let remaining: Double?
        let percentage: Double?
        let nextResetTime: Double?

        var asMetric: Metric? {
            switch type {
            case "TIME_LIMIT":
                return Metric(label: "Prompt window", used: usage, limit: usageLimit,
                              percentUsed: percentage, unit: .requests,
                              resetAt: dateFromEpochMillis(nextResetTime))
            case "TOKENS_LIMIT":
                return Metric(label: "Token budget", percentUsed: percentage, unit: .tokens,
                              resetAt: dateFromEpochMillis(nextResetTime))
            default:
                return nil
            }
        }
        // z.ai gives `usage` (the cap) + `remaining`; derive the limit when both present.
        private var usageLimit: Double? { usage }
    }

    // MARK: - webview plumbing

    private var loadContinuation: CheckedContinuation<Void, Error>?

    private func loadUsagePage() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            self.loadContinuation = c
            self.webView.load(URLRequest(url: usagePageURL))
        }
    }

    /// Runs the probe as an async function body. `callAsyncJavaScript` awaits the
    /// promise and returns the resolved value (a String here). We stay on the main
    /// actor throughout, so the non-Sendable `Any?` never crosses an actor boundary.
    private func evaluateString(_ jsBody: String) async throws -> String? {
        let result = try await webView.callAsyncJavaScript(
            jsBody, arguments: [:], in: nil, contentWorld: .page)
        return result as? String
    }
}

extension ZaiCollector: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadContinuation?.resume(); loadContinuation = nil
    }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: error); loadContinuation = nil
    }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: error); loadContinuation = nil
    }
}
