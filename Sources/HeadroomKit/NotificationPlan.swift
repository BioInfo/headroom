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
}

/// Memory carried between evaluations. A pure value owned by the caller (the `Notifier`),
/// so the transition logic itself stays side-effect-free and testable.
public struct AlertState: Sendable, Equatable {
    /// Meter key → the highest percent threshold already alerted, so a crossing fires once.
    public var firedAt: [String: Int]
    /// Meter keys currently exhausted (≥100%), so `exhausted`/`restored` each fire once.
    public var depleted: Set<String>

    public init(firedAt: [String: Int] = [:], depleted: Set<String> = []) {
        self.firedAt = firedAt
        self.depleted = depleted
    }

    /// Reset all memory (notifications turned fully off).
    public mutating func clear() { firedAt.removeAll(); depleted.removeAll() }
}

public enum NotificationPlan {
    /// Stable per-meter key. Matches the identifier the notifier posts under.
    public static func key(_ providerID: String, _ meterLabel: String) -> String {
        "\(providerID)|\(meterLabel)"
    }

    /// Decide the alerts to post for the latest readings and the state to carry forward.
    /// Pure — no clock, no side effects. `thresholds` are percents; `onReset` gates the
    /// soft "refilled" ping, `onDeplete` gates the "exhausted"/"restored" pair.
    ///
    /// Ordering guarantees:
    /// - `exhausted`/`restored` are threshold-independent (fire at the cap even if the user
    ///   set no threshold that high, or disabled thresholds' reset ping).
    /// - On a reset that follows an exhaustion, only the stronger `restored` fires — the
    ///   `refilled` ping is suppressed so the same reset never double-alerts.
    /// - Only authoritative, capped meters count (`fractionUsed` is nil for unlimited).
    public static func evaluate(_ usages: [ProviderUsage], thresholds: [Int],
                                onReset: Bool, onDeplete: Bool,
                                state: AlertState) -> (alerts: [UsageAlert], state: AlertState) {
        var st = state
        // If depletion alerts are off, don't strand exhausted-state that would fire a stray
        // "restored" later; the reset then falls through to the normal `refilled` path.
        if !onDeplete { st.depleted.removeAll() }

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
