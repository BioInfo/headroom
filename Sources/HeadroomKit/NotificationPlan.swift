import Foundation

// Notification transitions, as pure logic over `[ProviderUsage]` + carried state. The app
// layer turns each `UsageAlert` into a `UNUserNotification`; keeping the decision here makes
// the (subtle, double-fire-prone) transition rules unit-testable — the same HeadroomKit-first
// discipline the rest of the derived views follow.

/// One alert the app should post, decided from a usage transition between refreshes.
public enum UsageAlert: Sendable, Equatable {
    /// Usage climbed up through a configured threshold (e.g. 75/90/95%). Fires once per
    /// crossing, at the highest threshold passed.
    case crossed(provider: String, meter: String, percent: Int, resetAt: Date?)
    /// The window hit its cap (≥100% used) — you're locked out until it resets. Fires once,
    /// independent of the configured thresholds (the highest-value alert a quota app gives).
    case exhausted(provider: String, meter: String, resetAt: Date?)
    /// A window that had been exhausted reset and is usable again.
    case restored(provider: String, meter: String)
    /// A meter that had crossed a threshold (but never hit the cap) fell back below all of
    /// them — its window refilled. The softer counterpart to `restored`.
    case refilled(provider: String, meter: String)
    /// The meter crossed into pace deficit — at the current average rate it runs out before
    /// the window resets. Predictive (fires while there's still time to slow down), one per
    /// risk episode: re-arms only after the meter returns to even/reserve or the window resets.
    case paceRisk(provider: String, meter: String, deficitPercent: Int, runsOutAt: Date?)
}

/// Memory carried between evaluations. A pure value owned by the caller (the `Notifier`),
/// so the transition logic itself stays side-effect-free and testable.
public struct AlertState: Sendable, Equatable {
    /// Meter key → the highest percent threshold already alerted, so a crossing fires once.
    public var firedAt: [String: Int]
    /// Meter keys currently exhausted (≥100%), so `exhausted`/`restored` each fire once.
    public var depleted: Set<String>
    /// Meter keys inside an active pace-risk episode (alerted on entering deficit; cleared
    /// when the meter returns to even/reserve or the window resets), so `paceRisk` fires
    /// once per episode. The ±2% even band is the hysteresis — a meter hovering on the
    /// line lands in `.even` and stays in-episode rather than flapping.
    public var pacing: Set<String>

    public init(firedAt: [String: Int] = [:], depleted: Set<String> = [], pacing: Set<String> = []) {
        self.firedAt = firedAt
        self.depleted = depleted
        self.pacing = pacing
    }

    /// Reset all memory (notifications turned fully off).
    public mutating func clear() { firedAt.removeAll(); depleted.removeAll(); pacing.removeAll() }
}

public enum NotificationPlan {
    /// Stable per-meter key. Matches the identifier the notifier posts under.
    public static func key(_ providerID: String, _ meterLabel: String) -> String {
        "\(providerID)|\(meterLabel)"
    }

    /// Decide the alerts to post for the latest readings and the state to carry forward.
    /// Pure — the clock comes in as `now` (pace projection needs one), no side effects.
    /// `thresholds` are percents; `onReset` gates the soft "refilled" ping, `onDeplete`
    /// the "exhausted"/"restored" pair, `onPace` the predictive pace-risk alert.
    ///
    /// Ordering guarantees:
    /// - `exhausted`/`restored` are threshold-independent (fire at the cap even if the user
    ///   set no threshold that high, or disabled thresholds' reset ping).
    /// - On a reset that follows an exhaustion, only the stronger `restored` fires — the
    ///   `refilled` ping is suppressed so the same reset never double-alerts.
    /// - `paceRisk` fires once per episode: on entering deficit. The episode ends (re-arms)
    ///   only when the meter returns to reserve or the window resets — the `.even` dead band
    ///   and exhaustion both hold the episode, so a meter hovering on the line can't flap.
    /// - Only authoritative, capped meters count (`fractionUsed` is nil for unlimited).
    public static func evaluate(_ usages: [ProviderUsage], thresholds: [Int],
                                onReset: Bool, onDeplete: Bool,
                                onPace: Bool = false, now: Date = Date(),
                                state: AlertState) -> (alerts: [UsageAlert], state: AlertState) {
        var st = state
        // If depletion alerts are off, don't strand exhausted-state that would fire a stray
        // "restored" later; the reset then falls through to the normal `refilled` path.
        if !onDeplete { st.depleted.removeAll() }
        if !onPace { st.pacing.removeAll() }   // same shape: no stale episodes if re-enabled

        var alerts: [UsageAlert] = []
        let sorted = thresholds.sorted()

        for u in usages {
            for m in u.metrics where m.authoritative {
                guard let frac = m.fractionUsed else { continue }   // nil = unlimited, skip
                let pct = frac * 100
                let k = key(u.id, m.label)
                let exhausted = frac >= 1.0
                let wasDepleted = st.depleted.contains(k)

                // Exhaustion transition — evaluated first so a reset here can suppress the
                // softer refilled ping below.
                if onDeplete {
                    if exhausted, !wasDepleted {
                        alerts.append(.exhausted(provider: u.displayName, meter: m.label, resetAt: m.resetAt))
                        st.depleted.insert(k)
                    } else if !exhausted, wasDepleted {
                        alerts.append(.restored(provider: u.displayName, meter: m.label))
                        st.depleted.remove(k)
                    }
                }

                // Pace-risk episode: alert on ENTERING deficit (predictive — there's still
                // time to slow down). Exiting requires a clear return to reserve or a fresh
                // window (frac near zero); `.even`, exhaustion, and early-window nil all
                // hold the episode so it can't flap or double-fire.
                if onPace {
                    let pace = m.paceStatus(asOf: now)
                    if pace?.kind == .deficit, !st.pacing.contains(k) {
                        alerts.append(.paceRisk(provider: u.displayName, meter: m.label,
                                                deficitPercent: pace?.marginPercent ?? 0,
                                                runsOutAt: pace?.runsOutAt))
                        st.pacing.insert(k)
                    } else if st.pacing.contains(k), pace?.kind == .reserve || frac <= 0.05 {
                        st.pacing.remove(k)
                    }
                }

                // Threshold crossings (unchanged behavior): fire once per higher crossing.
                let crossed = sorted.filter { Double($0) <= pct }.max()
                let prior = st.firedAt[k]
                if let c = crossed {
                    if prior == nil || c > prior! {
                        alerts.append(.crossed(provider: u.displayName, meter: m.label,
                                               percent: Int(pct.rounded()), resetAt: m.resetAt))
                        st.firedAt[k] = c
                    }
                } else {
                    // Below every threshold: the window refilled. Suppress this softer ping
                    // when the same reset already emitted `restored` (was exhausted).
                    if prior != nil, onReset, !wasDepleted {
                        alerts.append(.refilled(provider: u.displayName, meter: m.label))
                    }
                    st.firedAt[k] = nil
                }
            }
        }
        return (alerts, st)
    }
}
