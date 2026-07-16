import Foundation

/// Where a window meter stands against its even-burn line, in user language: how much is
/// banked ("in reserve") or overdrawn ("in deficit"), and where that trajectory lands.
/// Pure — built from a `Metric` + a clock; the card renders it, the notifier alerts on it.
///
/// Deficit and exhaustion are the same fact at average rate: used > elapsed ⟺ the linear
/// projection crosses 100% before the reset. So `.deficit` always carries a `runsOutAt`.
public struct PaceStatus: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case reserve    // under even-burn: margin banked, lasts until reset at this rate
        case even       // within the dead zone of the even-burn line
        case deficit    // over even-burn: on pace to run out before the reset
    }

    public let kind: Kind
    /// used − elapsed. Positive = deficit, negative = reserve. The dead zone (±2%) maps
    /// to `.even` so the label doesn't flap between "1% in reserve" and "1% in deficit".
    public let margin: Double
    /// Landing fraction at reset if the average rate holds (used / elapsed). Can exceed 1.
    public let projected: Double
    /// Projected moment usage hits 100% at the average rate — set only for `.deficit`
    /// (in reserve/even you don't run out this window).
    public let runsOutAt: Date?
    /// Fraction of the window elapsed, 0...1.
    public let elapsed: Double

    /// Margin as whole percent, for display ("8% in reserve").
    public var marginPercent: Int { Int((abs(margin) * 100).rounded()) }

    /// Dead zone half-width around the even-burn line.
    public static let evenBand = 0.02
    /// Below this much of the window elapsed, pace is statistically noise — hide it.
    public static let minElapsed = 0.03
    /// A run-out clock time only reads right intra-day; farther out, show the landing %.
    public static let clockHorizon: TimeInterval = 16 * 3600

    /// The card/alert phrase:
    ///  reserve  → "8% in reserve · lasts until reset"
    ///  even     → "on pace · lands ~98%"
    ///  deficit  → "12% in deficit · runs out ~9:27 PM"  (or "· lands ~140%" beyond the
    ///              clock horizon, where a bare time would read as today and mislead)
    public func summary(now: Date = Date()) -> String {
        switch kind {
        case .reserve:
            return "\(marginPercent)% in reserve · lasts until reset"
        case .even:
            return "on pace · lands ~\(Int((projected * 100).rounded()))%"
        case .deficit:
            if let out = runsOutAt, out.timeIntervalSince(now) < Self.clockHorizon {
                return "\(marginPercent)% in deficit · runs out ~\(out.formatted(date: .omitted, time: .shortened))"
            }
            return "\(marginPercent)% in deficit · lands ~\(Int((projected * 100).rounded()))%"
        }
    }

    /// The compact card form, for when the reset time is already on the line ("resets in
    /// 2 hours · 8% in reserve" — repeating "lasts until reset" there would say it twice).
    /// Deficit keeps its full run-out/landing clause — that's the news.
    public func shortSummary(now: Date = Date()) -> String {
        switch kind {
        case .reserve: "\(marginPercent)% in reserve"
        case .even:    "on pace"
        case .deficit: summary(now: now)
        }
    }
}

public extension Metric {
    /// Pace against the even-burn line, or nil when it can't be read honestly: no window,
    /// no usage reading, under 3% of the window elapsed (noise), or already exhausted (the
    /// reset countdown owns that state — a pace phrase would be stale advice).
    func paceStatus(asOf now: Date = Date()) -> PaceStatus? {
        guard let reset = resetAt, let dur = windowDuration, dur > 0,
              let used = fractionUsed, used < 1.0 else { return nil }
        let start = reset.addingTimeInterval(-dur)
        let elapsed = min(max(now.timeIntervalSince(start) / dur, 0), 1)
        guard elapsed >= PaceStatus.minElapsed else { return nil }

        let margin = used - elapsed
        let projected = used / elapsed
        let kind: PaceStatus.Kind = abs(margin) < PaceStatus.evenBand ? .even
            : (margin > 0 ? .deficit : .reserve)
        // Linear from the window start: usage hits 1.0 at τ* = elapsed/used of the window.
        let runsOutAt: Date? = (kind == .deficit && used > 0)
            ? start.addingTimeInterval((elapsed / used) * dur) : nil
        return PaceStatus(kind: kind, margin: margin, projected: projected,
                          runsOutAt: runsOutAt, elapsed: elapsed)
    }
}
