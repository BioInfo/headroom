import Testing
import Foundation
@testable import HeadroomKit

private let now = Date(timeIntervalSince1970: 1_000_000_000)
private func at(_ s: TimeInterval) -> Date { now.addingTimeInterval(s) }

@Test func exhaustedCountdownOnlyAtOrOverCap() {
    // Below the cap → nil (normal percent shows), regardless of reset presence.
    #expect(ExhaustedReset.countdown(fraction: 0.99, resetAt: at(3600), now: now) == nil)
    // At/over the cap with a future reset → countdown.
    #expect(ExhaustedReset.countdown(fraction: 1.0, resetAt: at(45 * 60), now: now) == "45m")
    #expect(ExhaustedReset.countdown(fraction: 1.43, resetAt: at(45 * 60), now: now) == "45m")
}

@Test func exhaustedCountdownNeedsAFutureReset() {
    #expect(ExhaustedReset.countdown(fraction: 1.0, resetAt: nil, now: now) == nil)          // unknown reset
    #expect(ExhaustedReset.countdown(fraction: 1.0, resetAt: at(-60), now: now) == nil)      // already passed
    #expect(ExhaustedReset.countdown(fraction: nil, resetAt: at(60), now: now) == nil)       // no reading
}

@Test func compactDurationUnits() {
    #expect(ExhaustedReset.compact(until: at(30), from: now) == "1m")            // never "0m"
    #expect(ExhaustedReset.compact(until: at(59 * 60), from: now) == "59m")
    #expect(ExhaustedReset.compact(until: at(90 * 60), from: now) == "2h")       // rounds
    #expect(ExhaustedReset.compact(until: at(23 * 3600), from: now) == "23h")
    #expect(ExhaustedReset.compact(until: at(2 * 86400), from: now) == "2d")
}
