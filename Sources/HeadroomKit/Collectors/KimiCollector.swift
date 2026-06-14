import Foundation
import WebKit

/// Kimi (Moonshot) coding-plan headroom collector.
///
/// Mechanism (captured + proven live, see docs/PROVIDERS.md): a persistent WKWebView
/// holds the logged-in kimi.com session. We `callAsyncJavaScript` a probe that reads the
/// access-token JWT from the page's `localStorage.access_token` and replays the console's
/// own usage RPC:
///
///   POST www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages
///        body {"scope":["FEATURE_CODING"]}   header authorization: Bearer <jwt>
///
/// The token never leaves the webview. Cookie-only auth is rejected (401
/// REASON_INVALID_AUTH_TOKEN), and the documented `api.moonshot.ai/.../balance` is a USD
/// credit balance — the wrong meter — so there is no local-key path; this is webview-only,
/// like the z.ai fallback. The response gives the coding quota as used/100 (already a
/// percentage): a 5-hour rolling sub-window (`limits[0]`, window.duration 300min) plus the
/// plan-period cap (`usages[0].detail`). Plan name comes from a second call to
/// `MembershipService/GetSubscription` → `subscription.goods.title` (e.g. "Allegretto").
@MainActor
public final class KimiCollector: NSObject, Collector {
    public let id = "kimi"
    public let displayName = "Kimi"

    private let consoleURL = URL(string: "https://www.kimi.com/code/console")!
    private let webView: WKWebView

    public override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()   // persists cookies + localStorage across launches
        self.webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        self.webView.navigationDelegate = self
    }

    // The exact payload proven in the DevTools spike, as a function BODY for
    // callAsyncJavaScript. Reset times come back as epoch ms (computed in-page) so Swift
    // reuses `dateFromEpochMillis` and never parses Kimi's ISO-with-microseconds strings.
    private static let probeJS = """
    const tok = localStorage.getItem("access_token");
    if (!tok) return JSON.stringify({ ok:false, reason:"no-session" });
    const base = "https://www.kimi.com/apiv2/";
    const hdr = { "content-type":"application/json", "connect-protocol-version":"1",
                  "authorization":"Bearer "+tok };
    const unitSec = { TIME_UNIT_SECOND:1, TIME_UNIT_MINUTE:60, TIME_UNIT_HOUR:3600, TIME_UNIT_DAY:86400 };
    try {
      const ur = await fetch(base+"kimi.gateway.billing.v1.BillingService/GetUsages",
        { method:"POST", headers:hdr, body:JSON.stringify({ scope:["FEATURE_CODING"] }) });
      if (ur.status === 401) return JSON.stringify({ ok:false, reason:"no-session" });
      if (!ur.ok) return JSON.stringify({ ok:false, reason:"http-"+ur.status });
      const u = await ur.json();
      const feat = (u.usages||[]).find(x => x.scope === "FEATURE_CODING") || (u.usages||[])[0] || {};
      const windows = [];
      for (const lim of (feat.limits || [])) {
        const d = lim.detail || {}, w = lim.window || {};
        const durSec = w.duration ? w.duration * (unitSec[w.timeUnit] || 60) : null;
        const label = durSec === 18000 ? "5h window"
                    : (durSec ? Math.round(durSec/3600) + "h window" : "window");
        windows.push({ label, percentUsed: Number(d.used),
          resetMs: d.resetTime ? new Date(d.resetTime).getTime() : null, durationSec: durSec });
      }
      if (feat.detail) {
        windows.push({ label:"Plan window", percentUsed: Number(feat.detail.used),
          resetMs: feat.detail.resetTime ? new Date(feat.detail.resetTime).getTime() : null,
          durationSec: null });
      }
      let plan = null;
      try {
        const sr = await fetch(base+"kimi.gateway.membership.v2.MembershipService/GetSubscription",
          { method:"POST", headers:hdr, body:"{}" });
        if (sr.ok) { const s = await sr.json(); plan = (s && s.subscription && s.subscription.goods && s.subscription.goods.title) || null; }
      } catch (e) {}
      return JSON.stringify({ ok:true, plan, windows });
    } catch (e) { return JSON.stringify({ ok:false, reason:String(e) }); }
    """

    public func collect() async throws -> ProviderUsage {
        try await loadConsole()
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
        let metrics = Self.metrics(from: probe.windows ?? [])
        return ProviderUsage(provider: id, displayName: displayName, plan: probe.plan,
                             metrics: metrics, status: .ok)
    }

    /// The WKWebView usable for an in-app login window when there's no session.
    public var loginWebView: WKWebView { webView }
    public func startLogin() { webView.load(URLRequest(url: consoleURL)) }

    // MARK: - parsing (split out so tests can hit it with captured JSON)

    static func metrics(from windows: [Win]) -> [Metric] {
        windows.map { $0.asMetric }
    }

    struct Probe: Decodable {
        let ok: Bool
        let reason: String?
        let plan: String?
        let windows: [Win]?
    }
    struct Win: Decodable {
        let label: String
        let percentUsed: Double?
        let resetMs: Double?
        let durationSec: Double?

        var asMetric: Metric {
            Metric(label: label, percentUsed: percentUsed, unit: .percent,
                   resetAt: dateFromEpochMillis(resetMs), windowDuration: durationSec)
        }
    }

    // MARK: - webview plumbing (mirrors ZaiCollector)

    private var loadContinuation: CheckedContinuation<Void, Error>?

    private func loadConsole() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            self.loadContinuation = c
            self.webView.load(URLRequest(url: consoleURL))
        }
    }

    private func evaluateString(_ jsBody: String) async throws -> String? {
        let result = try await webView.callAsyncJavaScript(
            jsBody, arguments: [:], in: nil, contentWorld: .page)
        return result as? String
    }
}

extension KimiCollector: WKNavigationDelegate {
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
