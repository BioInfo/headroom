import Testing
import Foundation
@testable import HeadroomKit

// MARK: blended capacity

private func usage(_ id: String, status: Status = .ok, _ metrics: [Metric]) -> ProviderUsage {
    ProviderUsage(provider: id, displayName: id.capitalized, metrics: metrics, status: status)
}

@Test func capacityBucketsByFraction() {
    #expect(CapacityBucket(tightestCapped: 0.10, hasUnlimited: false) == .comfortable)
    #expect(CapacityBucket(tightestCapped: 0.78, hasUnlimited: false) == .warming)
    #expect(CapacityBucket(tightestCapped: 0.92, hasUnlimited: false) == .tight)
    #expect(CapacityBucket(tightestCapped: 1.20, hasUnlimited: false) == .tight)   // over-cap still tight
    #expect(CapacityBucket(tightestCapped: nil, hasUnlimited: true) == .unlimited)
    #expect(CapacityBucket(tightestCapped: nil, hasUnlimited: false) == .unknown)
}

@Test func capacitySummaryCountsAndHeadline() {
    let s = CapacitySummary.from([
        usage("claude", [Metric(label: "5h", percentUsed: 20, unit: .percent)]),    // comfortable
        usage("codex",  [Metric(label: "5h", percentUsed: 50, unit: .percent)]),    // comfortable
        usage("zai",    [Metric(label: "tok", percentUsed: 91, unit: .percent)]),   // tight, hottest
        usage("minimax",[Metric(label: "wk", unit: .percent, unlimited: true)]),    // unlimited
        usage("kimi", status: .needsLogin, []),                                     // unknown
    ])
    #expect(s.count(.comfortable) == 2)
    #expect(s.count(.tight) == 1)
    #expect(s.count(.unlimited) == 1)
    #expect(s.count(.unknown) == 1)
    #expect(s.live == 4)
    #expect(s.hottest?.name == "Zai")
    #expect(s.phrase == "2 comfortable · 1 tight · 1 unlimited")
}

@Test func capacityHottestHiddenWhenAllCool() {
    let s = CapacitySummary.from([
        usage("claude", [Metric(label: "5h", percentUsed: 30, unit: .percent)]),
        usage("codex",  [Metric(label: "5h", percentUsed: 12, unit: .percent)]),
    ])
    #expect(s.hottest == nil)                 // nothing ≥70% → no callout
    #expect(s.phrase == "2 comfortable")
}

@Test func capacityEmptyPhraseNil() {
    let s = CapacitySummary.from([usage("kimi", status: .error, [])])
    #expect(s.phrase == nil)                  // only unknowns → hide the row
    #expect(s.live == 0)
}

// MARK: reset timeline

@Test func resetTimelineSortsSoonestFirstAndSkipsPastAndUnlimited() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let soon = now.addingTimeInterval(3600)
    let later = now.addingTimeInterval(7200)
    let past = now.addingTimeInterval(-60)
    let entries = ResetTimeline.from([
        usage("claude", [Metric(label: "5h", percentUsed: 40, unit: .percent, resetAt: later)]),
        usage("codex",  [Metric(label: "5h", percentUsed: 80, unit: .percent, resetAt: soon)]),
        usage("zai",    [Metric(label: "old", percentUsed: 10, unit: .percent, resetAt: past)]),     // past → skip
        usage("minimax",[Metric(label: "wk", unit: .percent, resetAt: soon, unlimited: true)]),      // unlimited → skip
    ], now: now)
    #expect(entries.map(\.provider) == ["codex", "claude"])
    #expect(entries.first?.fractionUsed == 0.80)
}
