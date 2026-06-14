import Foundation

/// A real desktop-Safari user agent for the login WKWebViews.
///
/// Google refuses OAuth sign-in inside an embedded webview (its "disallowed_useragent"
/// policy, in force since 2016) — the default WKWebView UA gives it away and the sign-in
/// page just hangs. Presenting a normal desktop Safari UA lets Google's flow proceed,
/// which matters for any provider whose login is Google OAuth (Kimi, z.ai).
public enum WebUserAgent {
    public static let desktopSafari =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
}
