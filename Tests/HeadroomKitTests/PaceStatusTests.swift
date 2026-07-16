import Testing
import Foundation
@testable import HeadroomKit

@Suite("Pace status — reserve/deficit vs even burn")
struct PaceStatusTests {
    // Fixed clock: a 5h window resetting 2h from now is 60% elapsed.
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let h5: TimeInterval = 5 * 3600

    func window5h(usedPercent: Double, resetIn: TimeInterval = 2 * 3600) -> Metric {
        Metric(label: "5h", percentUsed: usedPercent, unit: .percent,
               resetAt: now.addingTimeInterval(resetIn), windowDuration: h5)
    }

    @Test func reserveWhenUnderEvenBurn() {
        // 40% used at 60% elapsed → 20% in reserve.
        let p = window5h(usedPercent: 40).paceStatus(asOf: now)!
        #expect(p.kind == .reserve)
        #expect(p.marginPercent == 20)
        #expect(p.runsOutAt == nil)
        #expect(p.summary(now: now) == "20% in reserve · lasts until reset")
        #expect(p.shortSummary(now: now) == "20% in reserve")
    }

    @Test func evenInsideDeadBand() {
        // 61% used at 60% elapsed → within ±2% band.
        let p = window5h(usedPercent: 61).paceStatus(asOf: now)!
        #expect(p.kind == .even)
        #expect(p.shortSummary(now: now) == "on pace")
        #expect(p.summary(now: now).hasPrefix("on pace · lands ~"))
    }

    @Test func deficitCarriesRunOutBeforeReset() {
        // 88% used at 60% elapsed → 28% deficit; runs out at τ* = 0.6/0.88 of the window.
        let m = window5h(usedPercent: 88)
        let p = m.paceStatus(asOf: now)!
        #expect(p.kind == .deficit)
        #expect(p.marginPercent == 28)
        let start = m.resetAt!.addingTimeInterval(-h5)
        let expected = start.addingTimeInterval((0.6 / 0.88) * h5)
        #expect(abs(p.runsOutAt!.timeIntervalSince(expected)) < 1)
        #expect(p.runsOutAt! < m.resetAt!)                      // deficit ⇒ runs out this window
        #expect(p.summary(now: now).contains("28% in deficit · runs out ~"))
        #expect(p.shortSummary(now: now) == p.summary(now: now)) // deficit keeps the full clause
    }

    @Test func weeklyDeficitBeyondClockHorizonShowsLanding() {
        // Weekly window 10% elapsed, 20% used → deficit, but the run-out is days away:
        // a bare clock time would read as today, so the phrase falls back to the landing %.
        let week: TimeInterval = 604_800
        let m = Metric(label: "Weekly", percentUsed: 20, unit: .percent,
                       resetAt: now.addingTimeInterval(week * 0.9), windowDuration: week)
        let p = m.paceStatus(asOf: now)!
        #expect(p.kind == .deficit)
        #expect(p.runsOutAt!.timeIntervalSince(now) > PaceStatus.clockHorizon)
        #expect(p.summary(now: now) == "10% in deficit · lands ~200%")
    }

    @Test func hiddenBelowThreePercentElapsed() {
        // 2% elapsed — below the 3% floor.
        let m = Metric(label: "5h", percentUsed: 10, unit: .percent,
                       resetAt: now.addingTimeInterval(4.9 * 3600), windowDuration: h5)
        #expect(m.paceStatus(asOf: now) == nil)
        // 3.2% elapsed — just above: visible.
        let m2 = Metric(label: "5h", percentUsed: 10, unit: .percent,
                        resetAt: now.addingTimeInterval(4.84 * 3600), windowDuration: h5)
        #expect(m2.paceStatus(asOf: now) != nil)
    }

    @Test func exhaustedAndUnlimitedAndWindowlessReturnNil() {
        #expect(window5h(usedPercent: 100).paceStatus(asOf: now) == nil)   // reset countdown owns it
        let unlimited = Metric(label: "Weekly", percentUsed: 50, unit: .percent,
                               resetAt: now.addingTimeInterval(3600), windowDuration: h5, unlimited: true)
        #expect(unlimited.paceStatus(asOf: now) == nil)
        let windowless = Metric(label: "extra", percentUsed: 50, unit: .percent,
                                resetAt: now.addingTimeInterval(3600))
        #expect(windowless.paceStatus(asOf: now) == nil)
    }
}

@Suite("NotificationPlan pace-risk episodes")
struct PaceAlertTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let h5: TimeInterval = 5 * 3600

    func usage(_ usedPercent: Double) -> [ProviderUsage] {
        [ProviderUsage(provider: "claude", displayName: "Claude", metrics: [
            Metric(label: "5h", percentUsed: usedPercent, unit: .percent,
                   resetAt: now.addingTimeInterval(2 * 3600), windowDuration: h5)  // 60% elapsed
        ])]
    }

    @Test func firesOncePerEpisodeAndHoldsThroughEvenAndExhaustion() {
        var st = AlertState()
        // Enter deficit → one alert.
        var r = NotificationPlan.evaluate(usage(88), thresholds: [], onReset: false,
                                          onDeplete: false, onPace: true, now: now, state: st)
        st = r.state
        #expect(r.alerts.count == 1)
        guard case let .paceRisk(provider, meter, deficit, runsOut) = r.alerts[0] else {
            Issue.record("expected paceRisk"); return
        }
        #expect(provider == "Claude"); #expect(meter == "5h")
        #expect(deficit == 28); #expect(runsOut != nil)
        // Still in deficit → silent.
        r = NotificationPlan.evaluate(usage(90), thresholds: [], onReset: false,
                                      onDeplete: false, onPace: true, now: now, state: st)
        st = r.state
        #expect(r.alerts.isEmpty)
        // Hovering in the even band → episode holds (no re-arm, no re-fire).
        r = NotificationPlan.evaluate(usage(61), thresholds: [], onReset: false,
                                      onDeplete: false, onPace: true, now: now, state: st)
        st = r.state
        #expect(r.alerts.isEmpty)
        #expect(st.pacing.count == 1)
        // Exhausted (paceStatus nil) → episode still holds.
        r = NotificationPlan.evaluate(usage(100), thresholds: [], onReset: false,
                                      onDeplete: false, onPace: true, now: now, state: st)
        st = r.state
        #expect(r.alerts.isEmpty)
        #expect(st.pacing.count == 1)
    }

    @Test func resetOrReserveEndsEpisodeAndReArms() {
        var st = AlertState(pacing: [NotificationPlan.key("claude", "5h")])
        // Fresh window (2% used) → episode cleared…
        var r = NotificationPlan.evaluate(usage(2), thresholds: [], onReset: false,
                                          onDeplete: false, onPace: true, now: now, state: st)
        st = r.state
        #expect(r.alerts.isEmpty)
        #expect(st.pacing.isEmpty)
        // …so the next deficit crossing fires again.
        r = NotificationPlan.evaluate(usage(88), thresholds: [], onReset: false,
                                      onDeplete: false, onPace: true, now: now, state: st)
        #expect(r.alerts.count == 1)
        // Clear return to reserve also ends an episode.
        var st2 = AlertState(pacing: [NotificationPlan.key("claude", "5h")])
        let r2 = NotificationPlan.evaluate(usage(40), thresholds: [], onReset: false,
                                           onDeplete: false, onPace: true, now: now, state: st2)
        st2 = r2.state
        #expect(st2.pacing.isEmpty)
    }

    @Test func offClearsEpisodesAndStaysSilent() {
        let st = AlertState(pacing: [NotificationPlan.key("claude", "5h")])
        let r = NotificationPlan.evaluate(usage(88), thresholds: [], onReset: false,
                                          onDeplete: false, onPace: false, now: now, state: st)
        #expect(r.alerts.isEmpty)
        #expect(r.state.pacing.isEmpty)
    }
}
