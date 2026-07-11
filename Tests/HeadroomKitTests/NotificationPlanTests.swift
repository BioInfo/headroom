import Testing
import Foundation
@testable import HeadroomKit

private func usage(_ provider: String, _ meter: String, pct: Double,
                   auth: Bool = true, unlimited: Bool = false, reset: Date? = nil) -> ProviderUsage {
    ProviderUsage(provider: provider, displayName: provider.capitalized,
                  metrics: [Metric(label: meter, percentUsed: pct, unit: .percent,
                                   resetAt: reset, authoritative: auth, unlimited: unlimited)])
}

private func eval(_ u: [ProviderUsage], thresholds: [Int] = [75, 90, 95],
                  onReset: Bool = true, onDeplete: Bool = true,
                  state: AlertState = .init()) -> (alerts: [UsageAlert], state: AlertState) {
    NotificationPlan.evaluate(u, thresholds: thresholds, onReset: onReset, onDeplete: onDeplete, state: state)
}

// MARK: - threshold crossings (must preserve the prior Notifier behavior)

@Test func crossingFiresOnceAtHighestPassed() {
    let r = eval([usage("claude", "5h", pct: 92)])
    #expect(r.alerts == [.crossed(provider: "Claude", meter: "5h", percent: 92, resetAt: nil)])
    #expect(r.state.firedAt["claude|5h"] == 90)   // highest threshold passed
}

@Test func stableReadingDoesNotReFire() {
    let r1 = eval([usage("claude", "5h", pct: 92)])
    let r2 = eval([usage("claude", "5h", pct: 93)], state: r1.state)   // still in the 90 band
    #expect(r2.alerts.isEmpty)
}

@Test func higherCrossingFiresAgain() {
    let r1 = eval([usage("claude", "5h", pct: 76)])
    #expect(r1.state.firedAt["claude|5h"] == 75)
    let r2 = eval([usage("claude", "5h", pct: 96)], state: r1.state)
    #expect(r2.alerts == [.crossed(provider: "Claude", meter: "5h", percent: 96, resetAt: nil)])
    #expect(r2.state.firedAt["claude|5h"] == 95)
}

@Test func belowAllThresholdsWithNoPriorIsSilent() {
    #expect(eval([usage("claude", "5h", pct: 40)]).alerts.isEmpty)
}

// MARK: - exhaustion / restoration

@Test func exhaustedFiresAtCap() {
    let r = eval([usage("codex", "weekly", pct: 100)])
    #expect(r.alerts.contains(.exhausted(provider: "Codex", meter: "weekly", resetAt: nil)))
    #expect(r.state.depleted.contains("codex|weekly"))
}

@Test func exhaustedFiresOverCap() {
    // A 130% extra-usage meter clamps fractionUsed to 1.0 → still exhausted.
    let r = eval([usage("claude", "extra", pct: 130)])
    #expect(r.alerts.contains(.exhausted(provider: "Claude", meter: "extra", resetAt: nil)))
}

@Test func exhaustedFiresOnceNotEveryTick() {
    let r1 = eval([usage("codex", "weekly", pct: 100)])
    let r2 = eval([usage("codex", "weekly", pct: 100)], state: r1.state)
    #expect(!r2.alerts.contains(where: { if case .exhausted = $0 { true } else { false } }))
}

@Test func exhaustedIsThresholdIndependent() {
    // No threshold set as high as 100, deplete still fires; and with thresholds empty entirely.
    let r = eval([usage("codex", "weekly", pct: 100)], thresholds: [])
    #expect(r.alerts == [.exhausted(provider: "Codex", meter: "weekly", resetAt: nil)])
}

@Test func restoredFiresWhenDepletedWindowResets() {
    let r1 = eval([usage("codex", "weekly", pct: 100)])
    let r2 = eval([usage("codex", "weekly", pct: 3)], state: r1.state)   // window reset
    #expect(r2.alerts.contains(.restored(provider: "Codex", meter: "weekly")))
    #expect(!r2.state.depleted.contains("codex|weekly"))
}

// MARK: - the no-double-fire guarantee (restored suppresses refilled on the same reset)

@Test func resetAfterExhaustionFiresRestoredOnly() {
    let r1 = eval([usage("codex", "weekly", pct: 100)])   // exhausted + depleted, firedAt=95
    let r2 = eval([usage("codex", "weekly", pct: 2)], state: r1.state)   // full reset
    #expect(r2.alerts == [.restored(provider: "Codex", meter: "weekly")])
    // crucially NOT also .refilled
    #expect(!r2.alerts.contains(.refilled(provider: "Codex", meter: "weekly")))
    #expect(r2.state.firedAt["codex|weekly"] == nil)
}

@Test func refilledFiresWhenCrossedButNeverExhausted() {
    let r1 = eval([usage("claude", "5h", pct: 80)])   // crossed 75, never exhausted
    let r2 = eval([usage("claude", "5h", pct: 5)], state: r1.state)
    #expect(r2.alerts == [.refilled(provider: "Claude", meter: "5h")])
}

// MARK: - gating

@Test func onResetOffSuppressesRefilled() {
    let r1 = eval([usage("claude", "5h", pct: 80)])
    let r2 = eval([usage("claude", "5h", pct: 5)], onReset: false, state: r1.state)
    #expect(r2.alerts.isEmpty)
}

@Test func onDepleteOffSuppressesExhaustedAndRestored() {
    let r1 = eval([usage("codex", "weekly", pct: 100)], onDeplete: false)
    #expect(!r1.alerts.contains(where: { if case .exhausted = $0 { true } else { false } }))
    #expect(r1.state.depleted.isEmpty)   // no exhausted-state stranded
    // On reset with deplete still off, it falls through to the normal refilled path.
    let r2 = eval([usage("codex", "weekly", pct: 2)], onDeplete: false, state: r1.state)
    #expect(r2.alerts == [.refilled(provider: "Codex", meter: "weekly")])
}

// MARK: - snooze contract (delivery is gated in the Notifier; state must still advance here)

@Test func evaluatingAdvancesStateSoADroppedAlertDoesNotResurface() {
    // Snooze drops the *delivery* of these alerts, but the Notifier still calls evaluate so
    // state advances. Simulate that: take the transition, discard its alerts, then evaluate
    // again on a stable reading — nothing should re-fire (no backlog dump on resume).
    let r1 = eval([usage("codex", "weekly", pct: 100)])
    #expect(!r1.alerts.isEmpty)                     // would have been delivered if not snoozed
    let r2 = eval([usage("codex", "weekly", pct: 100)], state: r1.state)   // resume, unchanged
    #expect(r2.alerts.isEmpty)                      // already recorded → silent
}

// MARK: - skips

@Test func unlimitedMeterIsIgnored() {
    let r = eval([usage("minimax", "weekly", pct: 100, unlimited: true)])
    #expect(r.alerts.isEmpty)
    #expect(r.state.depleted.isEmpty)
}

@Test func nonAuthoritativeMeterIsIgnored() {
    #expect(eval([usage("x", "est", pct: 100, auth: false)]).alerts.isEmpty)
}
