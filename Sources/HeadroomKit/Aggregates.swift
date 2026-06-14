import Foundation

// Cross-provider derived views. The whole point of a multi-provider tool: answers a
// single-provider tracker structurally can't give. Pure logic over `[ProviderUsage]` so
// it stays headless and unit-testable; the app layer just renders these.

// MARK: - Blended capacity ("3 comfortable · 1 tight")

/// How a provider's tightest meter reads, in one plain bucket. Coarser than `UsageTier`
/// on purpose — a glance summary, not a gauge.
public enum CapacityBucket: String, Sendable, CaseIterable {
    case comfortable   // tightest meter < 70%
    case warming       // 70–85%
    case tight         // ≥85% (pressing/critical/runaway)
    case unlimited     // an uncapped plan tier, nothing capped to worry about
    case unknown       // enabled but no live reading (needs login / error / no meters)

    /// Bucket a provider by its tightest authoritative capped fraction, or — absent one —
    /// whether it has an uncapped meter (unlimited) vs no usable reading (unknown).
    public init(tightestCapped: Double?, hasUnlimited: Bool) {
        if let f = tightestCapped {
            switch UsageTier(fraction: f) {
            case .healthy:                          self = .comfortable
            case .warming:                          self = .warming
            case .pressing, .critical, .runaway:    self = .tight
            }
        } else if hasUnlimited {
            self = .unlimited
        } else {
            self = .unknown
        }
    }
}

/// A count of providers per capacity bucket, plus the tightest single reading for the
/// headline. Equatable so the view only redraws on a real change.
public struct CapacitySummary: Sendable, Equatable {
    public var counts: [CapacityBucket: Int]
    /// Name + fraction of the single hottest provider, when one is genuinely under pressure.
    public let hottest: (name: String, fraction: Double)?
    /// Providers with any live reading (comfortable/warming/tight/unlimited) — what "of N" means.
    public let live: Int

    public static func == (l: CapacitySummary, r: CapacitySummary) -> Bool {
        l.counts == r.counts && l.live == r.live
            && l.hottest?.name == r.hottest?.name && l.hottest?.fraction == r.hottest?.fraction
    }

    public func count(_ b: CapacityBucket) -> Int { counts[b] ?? 0 }

    /// Build from current usages. `tightestCapped` is the max authoritative, capped
    /// fraction for a provider; `hasUnlimited` flags an uncapped meter on an OK/stale card.
    public static func from(_ usages: [ProviderUsage]) -> CapacitySummary {
        var counts: [CapacityBucket: Int] = [:]
        var hottest: (name: String, fraction: Double)?
        var live = 0
        for u in usages {
            let capped = u.metrics.filter { $0.authoritative && !$0.unlimited }
                .compactMap { $0.fractionUsed }.max()
            let hasUnlimited = (u.status == .ok || u.status == .stale)
                && u.metrics.contains { $0.unlimited }
            let bucket = CapacityBucket(tightestCapped: capped, hasUnlimited: hasUnlimited)
            counts[bucket, default: 0] += 1
            if bucket != .unknown { live += 1 }
            if let f = capped, f > (hottest?.fraction ?? -1) { hottest = (u.displayName, f) }
        }
        // Only surface a hottest headline when it's actually warm; coasting needs no callout.
        let headline = (hottest.map { $0.fraction >= 0.70 } == true) ? hottest : nil
        return CapacitySummary(counts: counts, hottest: headline, live: live)
    }

    /// A one-line human summary, omitting empty buckets: "3 comfortable · 1 tight · 1 unlimited".
    /// Empty (no live providers) → nil so the view can hide the row.
    public var phrase: String? {
        let order: [(CapacityBucket, String)] = [
            (.comfortable, "comfortable"), (.warming, "warming"),
            (.tight, "tight"), (.unlimited, "unlimited"),
        ]
        let parts = order.compactMap { (b, word) -> String? in
            let n = count(b)
            return n > 0 ? "\(n) \(word)" : nil
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Reset timeline ("what resets when", soonest first)

/// One capped window's next refill. Plan the day around the next provider that frees up.
public struct ResetEntry: Sendable, Identifiable, Equatable {
    public let provider: String
    public let displayName: String
    public let label: String            // the meter label ("5h window", "weekly")
    public let resetAt: Date
    public let fractionUsed: Double?     // how full now, for the color cue
    public var id: String { provider + "/" + label }

    public init(provider: String, displayName: String, label: String,
                resetAt: Date, fractionUsed: Double?) {
        self.provider = provider
        self.displayName = displayName
        self.label = label
        self.resetAt = resetAt
        self.fractionUsed = fractionUsed
    }
}

public enum ResetTimeline {
    /// Every capped meter that has a known reset, soonest first. Skips unlimited meters
    /// (nothing to refill) and resets already in the past (a stale reading mid-refresh).
    public static func from(_ usages: [ProviderUsage], now: Date = Date()) -> [ResetEntry] {
        usages.flatMap { u in
            u.metrics.compactMap { m -> ResetEntry? in
                guard !m.unlimited, let reset = m.resetAt, reset > now else { return nil }
                return ResetEntry(provider: u.provider, displayName: u.displayName,
                                  label: m.label, resetAt: reset, fractionUsed: m.fractionUsed)
            }
        }
        .sorted { $0.resetAt < $1.resetAt }
    }
}
