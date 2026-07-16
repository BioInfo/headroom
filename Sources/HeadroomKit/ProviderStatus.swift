import Foundation

/// A provider's *service* health (is the API up), distinct from your *usage* (how much you've
/// spent). Folds in the public status pages so a flat meter during an outage reads as "their
/// side is down," not "you're fine." Read-only public data; degrades to `.unknown` offline.
public enum ServiceHealth: String, Sendable, Equatable {
    case operational   // all good
    case degraded      // minor incident / partial
    case down          // major or critical outage
    case unknown       // no status source, or couldn't reach it (offline)

    /// Whether this is worth surfacing a dot for (operational + unknown stay quiet).
    public var isNotable: Bool { self == .degraded || self == .down }
}

/// Reads Atlassian Statuspage `/api/v2/status.json` for the providers that publish one.
/// Only Anthropic (Claude) and OpenAI (Codex) do today; the key/web providers have no
/// public status page, so they stay `.unknown` (no dot). Network fetch is isolated from
/// the parse so the mapping is unit-testable without hitting the network.
public enum ProviderStatus {
    /// Map a Statuspage `status.indicator` to our health enum.
    /// none → operational · minor → degraded · major/critical → down · else → unknown.
    public static func health(fromIndicator indicator: String) -> ServiceHealth {
        switch indicator.lowercased() {
        case "none":               .operational
        case "minor":              .degraded
        case "major", "critical":  .down
        default:                   .unknown
        }
    }

    /// Parse a Statuspage `/api/v2/status.json` body: `{ "status": { "indicator": "none", … } }`.
    public static func parse(_ data: Data) -> ServiceHealth {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = obj["status"] as? [String: Any],
              let indicator = status["indicator"] as? String else { return .unknown }
        return health(fromIndicator: indicator)
    }

    /// The Statuspage status.json URL for a provider, or nil if it publishes none.
    public static func statusURL(for provider: String) -> URL? {
        switch provider {
        case "claude", "claude-jands": URL(string: "https://status.claude.com/api/v2/status.json")  // status.anthropic.com 302s here
        case "codex":  URL(string: "https://status.openai.com/api/v2/status.json")
        default:       nil   // minimax / zai / kimi: no public status page
        }
    }

    /// Fetch one provider's current health. Any failure (offline, timeout, bad shape) →
    /// `.unknown`, so the feature never blocks or errors the app.
    public static func fetch(for provider: String,
                            session: URLSession = .shared) async -> ServiceHealth {
        guard let url = statusURL(for: provider) else { return .unknown }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return .unknown }
        return parse(data)
    }
}
