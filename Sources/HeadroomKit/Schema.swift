import Foundation

/// The normalized shape every collector produces. The whole app is a renderer over `[ProviderUsage]`.
public struct ProviderUsage: Codable, Sendable, Identifiable {
    public var id: String { provider }
    public let provider: String          // "zai", "claude", "codex", ...
    public let displayName: String       // "GLM (z.ai)"
    public var account: String?          // email / org label
    public var plan: String?             // "pro", "Max", "Coding Plan"
    public var metrics: [Metric]
    public var status: Status
    public var lastUpdated: Date

    public init(provider: String, displayName: String, account: String? = nil,
                plan: String? = nil, metrics: [Metric] = [], status: Status = .ok,
                lastUpdated: Date = Date()) {
        self.provider = provider
        self.displayName = displayName
        self.account = account
        self.plan = plan
        self.metrics = metrics
        self.status = status
        self.lastUpdated = lastUpdated
    }
}

/// One gauge. `limit == nil` means the provider exposes use but no cap.
public struct Metric: Codable, Sendable, Identifiable {
    public var id: String { label }
    public let label: String             // "5h window", "weekly", "tokens"
    public let used: Double?
    public let limit: Double?
    public let percentUsed: Double?      // 0...100, when the provider gives it directly
    public let unit: Unit
    public let resetAt: Date?
    /// Length of the rolling window in seconds, when the provider has a fixed one
    /// (Claude/Codex 5h = 18000, weekly = 604800). With `resetAt` this gives the
    /// window's start, which is what pace projection needs. nil = no even-burn line.
    public let windowDuration: TimeInterval?
    /// true = a real meter from the provider. false = estimated (e.g. spend vs a known cap).
    public let authoritative: Bool

    public init(label: String, used: Double? = nil, limit: Double? = nil,
                percentUsed: Double? = nil, unit: Unit, resetAt: Date? = nil,
                windowDuration: TimeInterval? = nil, authoritative: Bool = true) {
        self.label = label
        self.used = used
        self.limit = limit
        self.percentUsed = percentUsed
        self.unit = unit
        self.resetAt = resetAt
        self.windowDuration = windowDuration
        self.authoritative = authoritative
    }

    /// Fraction used in 0...1 for gauge rendering (bar width), derived from whichever
    /// fields are present. Clamped at both ends.
    public var fractionUsed: Double? {
        if let p = percentUsed { return min(max(p / 100.0, 0), 1) }
        if let u = used, let l = limit, l > 0 { return min(max(u / l, 0), 1) }
        return nil
    }

    /// Like `fractionUsed` but NOT clamped at the top, so over-cap meters (e.g. extra
    /// usage past 100%) can drive the `runaway` tier color. Use for severity, not width.
    public var severityFraction: Double? {
        if let p = percentUsed { return max(p / 100.0, 0) }
        if let u = used, let l = limit, l > 0 { return max(u / l, 0) }
        return nil
    }

    /// Where this window meter is headed. Needs `resetAt` + `windowDuration` + a usage
    /// reading. nil too early in the window to extrapolate, or for meters with no window.
    public func pace(asOf now: Date = Date()) -> Pace? {
        guard let reset = resetAt, let dur = windowDuration, dur > 0,
              let used = fractionUsed else { return nil }
        let start = reset.addingTimeInterval(-dur)
        let elapsed = min(max(now.timeIntervalSince(start) / dur, 0), 1)
        guard elapsed >= 0.05 else { return nil }  // too little of the window has passed
        return Pace(elapsed: elapsed, projected: used / elapsed)
    }

    /// True when usage is clearly past the even-burn line — the warning state.
    public func aheadOfPace(asOf now: Date = Date(), margin: Double = 0.05) -> Bool {
        guard let p = pace(asOf: now), let used = fractionUsed else { return false }
        return used > p.elapsed + margin
    }
}

/// Where a window meter is going: the even-burn line and the projected landing.
public struct Pace: Sendable, Equatable {
    /// Fraction of the window elapsed, 0...1 — where even-burn consumption would have you.
    public let elapsed: Double
    /// Fraction-used projected at reset if the current rate holds. Can exceed 1.0.
    public let projected: Double

    public init(elapsed: Double, projected: Double) {
        self.elapsed = elapsed
        self.projected = projected
    }

    /// You're on track to hit the cap before the window resets.
    public var willExhaust: Bool { projected >= 1.0 }
}

public enum Unit: String, Codable, Sendable {
    case tokens, requests, usd, percent
}

public enum Status: String, Codable, Sendable {
    case ok            // data is fresh and authoritative
    case needsLogin    // no session; user must log in
    case stale         // last good data, refresh failed
    case error         // collector failed
}
