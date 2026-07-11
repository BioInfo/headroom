import Foundation

/// Adaptive polling cadence: choose the base refresh interval from how recently the user
/// looked at Headroom and whether the machine is power- or thermally constrained. Poll fast
/// while they're watching, coast when they've stepped away, and back off hard on Low Power
/// Mode or heat. A pure function of its `Input` — it reads no clock and no `ProcessInfo`
/// itself, so it's fully deterministic and unit-testable. The caller gathers the impure
/// signals (current time, Low Power Mode, thermal state) immediately before each tick and
/// passes them in.
///
/// Every decision lands in the 2...30 minute range by construction. Interaction recency and
/// machine constraint are the only inputs: no quota, latency, error, account, or
/// time-of-day. That keeps the schedule predictable and privacy-clean — usage data never
/// feeds the timing, so a log line ("reason=warm delay=300s") leaks nothing.
///
/// The tier shape (recency bands under a constrained override) is borrowed from
/// steipete/CodexBar's `AdaptiveRefreshPolicy` (MIT) — the idea and the band table, our own
/// implementation. See the borrowed-with-pride ledger in docs/ROADMAP.md.
public enum AdaptiveCadence {
    /// Why a delay was chosen — a stable, loggable label. Never carries usage/account data.
    public enum Reason: String, Sendable, Equatable, CaseIterable {
        case constrained        // Low Power Mode or hot: back off to protect battery/thermals
        case recentInteraction  // you just looked — keep it live
        case warm               // looked within the last hour
        case idle               // looked within the last few hours
        case longIdle           // not looked at in a long while (or not yet this launch)

        /// A short human phrase for the Settings display ("Currently every 2 min · …").
        public var caption: String {
            switch self {
            case .constrained:       "saving power"
            case .recentInteraction: "you just looked"
            case .warm:              "looked recently"
            case .idle:              "idle a while"
            case .longIdle:          "idle"
            }
        }
    }

    /// The impure signals, gathered by the caller right before a tick.
    public struct Input: Sendable, Equatable {
        public let now: Date
        /// When the menu-bar popover was last opened this launch. In-memory only, never
        /// persisted; nil until the first open (or if never opened).
        public let lastMenuOpenAt: Date?
        /// `ProcessInfo.processInfo.isLowPowerModeEnabled`.
        public let lowPowerMode: Bool
        /// True when `ProcessInfo.processInfo.thermalState` is `.serious` or `.critical`.
        public let thermalConstrained: Bool

        public init(now: Date, lastMenuOpenAt: Date?, lowPowerMode: Bool, thermalConstrained: Bool) {
            self.now = now
            self.lastMenuOpenAt = lastMenuOpenAt
            self.lowPowerMode = lowPowerMode
            self.thermalConstrained = thermalConstrained
        }
    }

    /// The chosen next delay and the reason, for the caller to sleep on (and display/log).
    public struct Decision: Sendable, Equatable {
        public let delay: TimeInterval
        public let reason: Reason
        public init(delay: TimeInterval, reason: Reason) {
            self.delay = delay
            self.reason = reason
        }
        /// The delay in whole minutes, for display.
        public var minutes: Int { Int((delay / 60).rounded()) }
    }

    // Tier delays (seconds). The 2-min recent floor and 30-min ceiling bound every decision.
    static let recentDelay: TimeInterval      = 2 * 60
    static let warmDelay: TimeInterval        = 5 * 60
    static let idleDelay: TimeInterval        = 15 * 60
    static let longIdleDelay: TimeInterval    = 30 * 60
    static let constrainedDelay: TimeInterval = 30 * 60

    // Interaction-recency band edges (seconds), each an upper-open bound.
    static let recentWindow: TimeInterval = 5 * 60      // [0, 5 min)  → recent
    static let warmWindow: TimeInterval   = 60 * 60     // [5 min, 1 h) → warm
    static let idleWindow: TimeInterval   = 4 * 60 * 60 // [1 h, 4 h)  → idle; ≥ 4 h → longIdle

    /// Decide the next delay. First match wins:
    /// 1. Low Power Mode or hot → 30 min (`constrained`) — overrides recency.
    /// 2. menu opened under 5 min ago (a future/clock-skewed stamp counts as recent) → 2 min.
    /// 3. opened under 1 h ago → 5 min.
    /// 4. opened under 4 h ago → 15 min.
    /// 5. never opened this launch, or 4 h+ ago → 30 min.
    public static func decide(_ input: Input) -> Decision {
        if input.lowPowerMode || input.thermalConstrained {
            return Decision(delay: constrainedDelay, reason: .constrained)
        }
        guard let opened = input.lastMenuOpenAt else {
            return Decision(delay: longIdleDelay, reason: .longIdle)
        }
        // Negative when the stamp is in the future (clock adjustment) — falls in the recent
        // band, matching "you just looked" rather than jumping to a long back-off.
        let elapsed = input.now.timeIntervalSince(opened)
        switch elapsed {
        case ..<recentWindow: return Decision(delay: recentDelay, reason: .recentInteraction)
        case ..<warmWindow:   return Decision(delay: warmDelay, reason: .warm)
        case ..<idleWindow:   return Decision(delay: idleDelay, reason: .idle)
        default:              return Decision(delay: longIdleDelay, reason: .longIdle)
        }
    }
}
