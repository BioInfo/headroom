import Foundation

/// Menu-bar text swap for an exhausted meter: once a window hits its cap, "100%" tells you
/// nothing you don't already feel — when it comes back is the number that matters. When the
/// resolved meter is at/over 100% and has a future reset, the menu bar shows a compact
/// countdown ("45m", "3h", "2d") in place of the percent, then reverts after the reset.
/// (Idea from steipete/CodexBar's "Show reset time when quota runs out"; reimplemented.)
public enum ExhaustedReset {
    /// The compact countdown to show instead of the percent, or nil when the normal percent
    /// (or nothing) should render. Fires only at fraction >= 1 with a known future reset.
    public static func countdown(fraction: Double?, resetAt: Date?, now: Date = Date()) -> String? {
        guard let f = fraction, f >= 1.0, let r = resetAt, r > now else { return nil }
        return compact(until: r, from: now)
    }

    /// Compact duration: minutes under an hour, hours under a day, else days. Never "0m" —
    /// an imminent reset reads "1m".
    public static func compact(until: Date, from: Date) -> String {
        let s = until.timeIntervalSince(from)
        if s < 3600 { return "\(max(1, Int((s / 60).rounded())))m" }
        if s < 86400 { return "\(max(1, Int((s / 3600).rounded())))h" }
        return "\(max(1, Int((s / 86400).rounded())))d"
    }
}
