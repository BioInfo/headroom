import Testing
import Foundation
@testable import HeadroomKit

@Suite("UsageTier thresholds")
struct UsageTierTests {
    @Test func boundariesMapToTiers() {
        #expect(UsageTier(fraction: 0.0)  == .healthy)
        #expect(UsageTier(fraction: 0.69) == .healthy)
        #expect(UsageTier(fraction: 0.70) == .warming)
        #expect(UsageTier(fraction: 0.84) == .warming)
        #expect(UsageTier(fraction: 0.85) == .pressing)
        #expect(UsageTier(fraction: 0.94) == .pressing)
        #expect(UsageTier(fraction: 0.95) == .critical)
        #expect(UsageTier(fraction: 1.00) == .critical)
        #expect(UsageTier(fraction: 1.01) == .runaway)
        #expect(UsageTier(fraction: 1.69) == .runaway)
    }

    @Test func rampReturnsAColorPerTier() {
        for tier in UsageTier.allCases {
            #expect(Theme.light.ramp(tier).count == 6)
            #expect(Theme.dark.ramp(tier).count == 6)
        }
    }
}

@Suite("Metric severity vs width")
struct MetricSeverityTests {
    @Test func fractionUsedClampsButSeverityDoesNot() {
        let over = Metric(label: "extra", percentUsed: 169, unit: .percent)
        #expect(over.fractionUsed == 1.0)          // bar width clamps
        #expect(over.severityFraction == 1.69)     // severity does not → runaway
        #expect(UsageTier(fraction: over.severityFraction!) == .runaway)
    }
}

@Suite("Pace projection")
struct PaceTests {
    // Fixed clock so the window math is deterministic.
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let h5: TimeInterval = 5 * 3600

    /// A 5h window resetting 2h from `now` is 60% elapsed.
    func window5h(usedPercent: Double) -> Metric {
        Metric(label: "5h", percentUsed: usedPercent, unit: .percent,
               resetAt: now.addingTimeInterval(2 * 3600), windowDuration: h5)
    }

    @Test func underPaceProjectsBelowOne() {
        let m = window5h(usedPercent: 33)
        let p = m.pace(asOf: now)!
        #expect(abs(p.elapsed - 0.6) < 1e-9)
        #expect(abs(p.projected - 0.55) < 1e-9)   // 0.33 / 0.6
        #expect(p.willExhaust == false)
        #expect(m.aheadOfPace(asOf: now) == false)
    }

    @Test func aheadOfPaceProjectsPastOne() {
        let m = window5h(usedPercent: 88)
        let p = m.pace(asOf: now)!
        #expect(p.projected > 1.0)                 // 0.88 / 0.6 ≈ 1.47
        #expect(p.willExhaust)
        #expect(m.aheadOfPace(asOf: now))
    }

    @Test func tooEarlyInWindowReturnsNil() {
        // Reset 4.9h away in a 5h window → 2% elapsed, below the 3% floor.
        let m = Metric(label: "5h", percentUsed: 10, unit: .percent,
                       resetAt: now.addingTimeInterval(4.9 * 3600), windowDuration: h5)
        #expect(m.pace(asOf: now) == nil)
    }

    @Test func noWindowDurationReturnsNil() {
        let m = Metric(label: "extra", percentUsed: 50, unit: .percent,
                       resetAt: now.addingTimeInterval(3600))
        #expect(m.pace(asOf: now) == nil)
        #expect(m.aheadOfPace(asOf: now) == false)
    }
}
