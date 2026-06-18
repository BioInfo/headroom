import Testing
import Foundation
@testable import HeadroomKit

/// Build a date at a given wall-clock time in US Eastern, so the tests pin the window
/// regardless of the machine's own time zone.
private func eastern(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = PeakHours.timeZone
    return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

// 2026-06-17 is a Wednesday; 06-20 Saturday; 06-21 Sunday.

@Test func peakDuringWeekdayWindow() {
    #expect(PeakHours.isPeak(eastern(2026, 6, 17, 10)))     // mid-window
    #expect(PeakHours.isPeak(eastern(2026, 6, 17, 8)))      // start inclusive
    #expect(PeakHours.isPeak(eastern(2026, 6, 17, 13, 59))) // just before end
}

@Test func offPeakOutsideTheHours() {
    #expect(!PeakHours.isPeak(eastern(2026, 6, 17, 6)))     // before 8am
    #expect(!PeakHours.isPeak(eastern(2026, 6, 17, 14)))    // end is exclusive
    #expect(!PeakHours.isPeak(eastern(2026, 6, 17, 21)))    // evening
}

@Test func offPeakOnWeekends() {
    #expect(!PeakHours.isPeak(eastern(2026, 6, 20, 10)))    // Saturday
    #expect(!PeakHours.isPeak(eastern(2026, 6, 21, 10)))    // Sunday
}
