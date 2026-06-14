import Foundation

/// How often a collector wants to be polled, relative to the user's base interval.
/// Local file reads are cheap → poll every tick; remote calls (network/webview) are
/// heavier and rate-limit-sensitive → poll at half the rate. Keeps the menu bar current
/// without hammering provider APIs or spinning a webview every cycle.
public enum RefreshCadence: Sendable, Equatable {
    case standard   // local creds / cheap reads — the user's base interval
    case relaxed    // remote (network or webview) — half as often

    /// Effective polling interval in seconds for a given base interval.
    public func interval(base: TimeInterval) -> TimeInterval {
        switch self {
        case .standard: base
        case .relaxed:  base * 2
        }
    }
}

/// One per provider. Independently toggleable and testable.
public protocol Collector: Sendable {
    /// Stable id, matches `ProviderUsage.provider`.
    var id: String { get }
    var displayName: String { get }
    /// How often to poll this provider. Local collectors keep the default (`.standard`);
    /// remote ones override to `.relaxed`.
    var cadence: RefreshCadence { get }
    /// Fetch current usage. Throws only on unexpected failure; expected states
    /// (no session, stale) come back as a `ProviderUsage` with the matching `status`.
    func collect() async throws -> ProviderUsage
}

public extension Collector {
    /// Default: poll at the base interval. Cheap local-creds collectors keep this.
    var cadence: RefreshCadence { .standard }

    /// Convenience for returning a "needs login" placeholder.
    func needsLogin(account: String? = nil, plan: String? = nil) -> ProviderUsage {
        ProviderUsage(provider: id, displayName: displayName, account: account,
                      plan: plan, metrics: [], status: .needsLogin)
    }
}

/// Helper: epoch milliseconds -> Date, the shape z.ai (and others) use for resets.
public func dateFromEpochMillis(_ ms: Double?) -> Date? {
    guard let ms else { return nil }
    return Date(timeIntervalSince1970: ms / 1000.0)
}
