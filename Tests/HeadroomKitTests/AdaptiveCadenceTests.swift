import Testing
import Foundation
@testable import HeadroomKit

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)   // fixed "now" for determinism

private func decide(openedAgo: TimeInterval?, lowPower: Bool = false, hot: Bool = false)
    -> AdaptiveCadence.Decision {
    let opened = openedAgo.map { t0.addingTimeInterval(-$0) }
    return AdaptiveCadence.decide(.init(now: t0, lastMenuOpenAt: opened,
                                        lowPowerMode: lowPower, thermalConstrained: hot))
}

// MARK: - recency bands

@Test func recentInteractionUnderFiveMinutes() {
    let d = decide(openedAgo: 60)        // 1 min ago
    #expect(d.reason == .recentInteraction)
    #expect(d.delay == 2 * 60)
    #expect(d.minutes == 2)
}

@Test func warmUnderOneHour() {
    let d = decide(openedAgo: 30 * 60)   // 30 min ago
    #expect(d.reason == .warm)
    #expect(d.delay == 5 * 60)
}

@Test func idleUnderFourHours() {
    let d = decide(openedAgo: 2 * 60 * 60)   // 2 h ago
    #expect(d.reason == .idle)
    #expect(d.delay == 15 * 60)
}

@Test func longIdleBeyondFourHours() {
    let d = decide(openedAgo: 5 * 60 * 60)   // 5 h ago
    #expect(d.reason == .longIdle)
    #expect(d.delay == 30 * 60)
}

@Test func neverOpenedThisLaunchIsLongIdle() {
    let d = decide(openedAgo: nil)
    #expect(d.reason == .longIdle)
    #expect(d.delay == 30 * 60)
}

// MARK: - band boundaries (each edge is an upper-open bound → the higher band)

@Test func exactlyFiveMinutesIsWarmNotRecent() {
    #expect(decide(openedAgo: 5 * 60).reason == .warm)
}

@Test func justUnderFiveMinutesIsRecent() {
    #expect(decide(openedAgo: 5 * 60 - 1).reason == .recentInteraction)
}

@Test func exactlyOneHourIsIdleNotWarm() {
    #expect(decide(openedAgo: 60 * 60).reason == .idle)
}

@Test func exactlyFourHoursIsLongIdleNotIdle() {
    #expect(decide(openedAgo: 4 * 60 * 60).reason == .longIdle)
}

// MARK: - constrained override wins over any recency

@Test func lowPowerOverridesRecentInteraction() {
    let d = decide(openedAgo: 10, lowPower: true)   // would be recent, but on Low Power
    #expect(d.reason == .constrained)
    #expect(d.delay == 30 * 60)
}

@Test func thermalOverridesRecentInteraction() {
    let d = decide(openedAgo: 10, hot: true)
    #expect(d.reason == .constrained)
    #expect(d.delay == 30 * 60)
}

@Test func constrainedAppliesEvenWithNoOpen() {
    #expect(decide(openedAgo: nil, lowPower: true).reason == .constrained)
}

// MARK: - clock adjustment: a future open stamp counts as recent, not a long back-off

@Test func futureOpenStampIsRecent() {
    let d = decide(openedAgo: -120)   // opened "in the future" (clock moved back)
    #expect(d.reason == .recentInteraction)
    #expect(d.delay == 2 * 60)
}

// MARK: - invariant: every decision is within 2...30 minutes

@Test func everyDecisionStaysInTwoToThirtyMinutes() {
    let agos: [TimeInterval?] = [nil, -300, 0, 1, 299, 300, 3599, 3600, 14399, 14400, 100_000]
    for ago in agos {
        for lp in [false, true] {
            for hot in [false, true] {
                let d = decide(openedAgo: ago, lowPower: lp, hot: hot)
                #expect(d.delay >= 2 * 60)
                #expect(d.delay <= 30 * 60)
            }
        }
    }
}
