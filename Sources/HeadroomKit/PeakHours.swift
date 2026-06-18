import Foundation

/// Claude's busy window heuristic. Anthropic doesn't publish a "peak hours" cap, but usage
/// pressure is observably worst on US weekday mornings into early afternoon — when limits
/// bite soonest. This is an inferred heuristic, not a documented schedule, so the indicator
/// that uses it ships opt-in (off by default).
public enum PeakHours {
    /// US Eastern, DST-aware (so the window tracks "ET", not a frozen offset).
    public static let timeZone = TimeZone(identifier: "America/New_York")!
    /// Window bounds in local Eastern, end-exclusive: 08:00 up to (not including) 14:00.
    public static let startHour = 8
    public static let endHour = 14

    /// True when `date` is inside the peak window: a US weekday (Mon–Fri), between
    /// `startHour` and `endHour` US Eastern.
    public static func isPeak(_ date: Date = Date()) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.weekday, .hour], from: date)
        guard let weekday = c.weekday, let hour = c.hour else { return false }
        let isWeekday = (2...6).contains(weekday)   // Gregorian: Sun=1 … Sat=7
        return isWeekday && hour >= startHour && hour < endHour
    }

    /// Human label for the window, dash-free per the house style.
    public static let windowLabel = "weekdays 8:00 AM to 2:00 PM ET"
}
