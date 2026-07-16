import Testing
import Foundation
@testable import HeadroomKit

@Suite("Burn-down sample store")
struct BurnHistoryTests {
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    // MARK: lane mapping

    @Test func laneMapping() {
        #expect(BurnLane.lane(forWindowSeconds: 5 * 3600) == .session)      // Claude/Codex 5h
        #expect(BurnLane.lane(forWindowSeconds: 3600) == .session)
        #expect(BurnLane.lane(forWindowSeconds: 604_800) == .week)          // weekly
        #expect(BurnLane.lane(forWindowSeconds: 86_400) == .week)           // daily still weekly-lane
        #expect(BurnLane.lane(forWindowSeconds: 30 * 86_400) == nil)        // monthly excluded
        #expect(BurnLane.lane(forWindowSeconds: 12 * 3600) == nil)          // between the lanes
        #expect(BurnLane.lane(forWindowSeconds: nil) == nil)
        #expect(BurnLane.lane(forWindowSeconds: 0) == nil)
    }

    // MARK: laneFractions extraction

    @Test func laneFractionsPicksTightestAndSkipsNonQualifying() {
        let u = ProviderUsage(provider: "claude", displayName: "Claude", metrics: [
            Metric(label: "5h window", percentUsed: 40, unit: .percent, windowDuration: 5 * 3600),
            Metric(label: "Weekly", percentUsed: 60, unit: .percent, windowDuration: 604_800),
            Metric(label: "Weekly (Opus)", percentUsed: 80, unit: .percent, windowDuration: 604_800),
            Metric(label: "Estimate", percentUsed: 99, unit: .percent, windowDuration: 604_800, authoritative: false),
            Metric(label: "Unlimited", percentUsed: 99, unit: .percent, windowDuration: 604_800, unlimited: true),
            Metric(label: "Monthly", percentUsed: 99, unit: .percent, windowDuration: 30 * 86_400),
            Metric(label: "No window", percentUsed: 99, unit: .percent),
        ])
        let lanes = BurnHistory.laneFractions(for: u)
        #expect(abs(lanes[.session]! - 0.40) < 0.0001)
        #expect(abs(lanes[.week]! - 0.80) < 0.0001)   // tightest weekly wins
        #expect(lanes.count == 2)
    }

    // MARK: record / coalesce

    @Test func flatRunKeepsOnlyEndpoints() {
        var h = BurnHistory()
        for i in 0..<10 {
            h.record(provider: "claude", lane: .session, fraction: 0.5,
                     at: t0.addingTimeInterval(Double(i) * 120))
        }
        let s = h.series(provider: "claude", lane: .session, since: .distantPast)
        #expect(s.count == 2)                       // run start + slid end
        #expect(s[0].t == t0)
        #expect(s[1].t == t0.addingTimeInterval(9 * 120))
        #expect(s[1].f == 0.5)
    }

    @Test func changingReadingsAppendAndResetIsKept() {
        var h = BurnHistory()
        h.record(provider: "codex", lane: .week, fraction: 0.3, at: t0)
        h.record(provider: "codex", lane: .week, fraction: 0.6, at: t0.addingTimeInterval(600))
        h.record(provider: "codex", lane: .week, fraction: 0.9, at: t0.addingTimeInterval(1200))
        h.record(provider: "codex", lane: .week, fraction: 0.02, at: t0.addingTimeInterval(1800)) // window reset
        let s = h.series(provider: "codex", lane: .week, since: .distantPast)
        #expect(s.map(\.f) == [0.3, 0.6, 0.9, 0.02])
    }

    @Test func stormGapDropsRapidRepeat() {
        var h = BurnHistory()
        h.record(provider: "claude", lane: .session, fraction: 0.5, at: t0)
        let changed = h.record(provider: "claude", lane: .session, fraction: 0.7,
                               at: t0.addingTimeInterval(5))   // 5s later — a refresh storm
        #expect(!changed)
        #expect(h.series(provider: "claude", lane: .session, since: .distantPast).count == 1)
    }

    @Test func fractionClamped() {
        var h = BurnHistory()
        h.record(provider: "glm", lane: .session, fraction: 1.7, at: t0)
        h.record(provider: "glm", lane: .session, fraction: -0.2, at: t0.addingTimeInterval(600))
        let s = h.series(provider: "glm", lane: .session, since: .distantPast)
        #expect(s.map(\.f) == [1.0, 0.0])
    }

    // MARK: prune / retention

    @Test func pruneDropsBeyondRetentionAndEmptyLanes() {
        var h = BurnHistory()
        h.record(provider: "claude", lane: .week, fraction: 0.5, at: t0.addingTimeInterval(-20 * 86_400))
        h.record(provider: "claude", lane: .week, fraction: 0.8, at: t0.addingTimeInterval(-3600))
        h.record(provider: "kimi", lane: .session, fraction: 0.4, at: t0.addingTimeInterval(-15 * 86_400))
        h.prune(now: t0)
        #expect(h.series(provider: "claude", lane: .week, since: .distantPast).map(\.f) == [0.8])
        #expect(h.series(provider: "kimi", lane: .session, since: .distantPast).isEmpty)
        #expect(h.providers(in: .week) == ["claude"])
        #expect(h.providers(in: .session) == [])
    }

    @Test func ringCapBoundsLane() {
        var h = BurnHistory()
        // Alternate fractions so nothing coalesces; exceed the cap.
        for i in 0..<(BurnHistory.maxPerLane + 100) {
            h.record(provider: "claude", lane: .session,
                     fraction: (i % 2 == 0) ? 0.3 : 0.7,
                     at: t0.addingTimeInterval(Double(i) * 60))
        }
        #expect(h.series(provider: "claude", lane: .session, since: .distantPast).count
                == BurnHistory.maxPerLane)
    }

    // MARK: series window + codable

    @Test func seriesSinceFilters() {
        var h = BurnHistory()
        h.record(provider: "claude", lane: .session, fraction: 0.1, at: t0)
        h.record(provider: "claude", lane: .session, fraction: 0.2, at: t0.addingTimeInterval(7200))
        let s = h.series(provider: "claude", lane: .session, since: t0.addingTimeInterval(3600))
        #expect(s.map(\.f) == [0.2])
    }

    @Test func codableRoundTrip() throws {
        var h = BurnHistory()
        h.record(provider: "claude", lane: .session, fraction: 0.42, at: t0)
        h.record(provider: "claude", lane: .week, fraction: 0.9, at: t0)
        let data = try JSONEncoder().encode(h)
        let back = try JSONDecoder().decode(BurnHistory.self, from: data)
        #expect(back == h)
    }
}
