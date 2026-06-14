import Foundation

/// One per provider. Independently toggleable and testable.
public protocol Collector: Sendable {
    /// Stable id, matches `ProviderUsage.provider`.
    var id: String { get }
    var displayName: String { get }
    /// Fetch current usage. Throws only on unexpected failure; expected states
    /// (no session, stale) come back as a `ProviderUsage` with the matching `status`.
    func collect() async throws -> ProviderUsage
}

public extension Collector {
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
