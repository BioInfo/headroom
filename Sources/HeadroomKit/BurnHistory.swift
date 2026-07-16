import Foundation

/// Which burn-down lane a window meter feeds. Lanes are keyed by window LENGTH, not label,
/// so every provider's "5h"-style meter lands in `.session` and every weekly meter in
/// `.week` regardless of what the provider calls it. Monthly windows are excluded — the
/// 14-day retention can't render a meaningful month burn-down.
public enum BurnLane: String, Codable, Sendable, CaseIterable {
    case session   // short rolling window (≤ 6h)
    case week      // the weekly window (1–8 days)

    public static func lane(forWindowSeconds s: TimeInterval?) -> BurnLane? {
        guard let s, s > 0 else { return nil }
        if s <= 6 * 3600 { return .session }
        if s >= 86400 && s <= 8 * 86400 { return .week }
        return nil
    }

    public var displayName: String {
        switch self { case .session: "Session"; case .week: "Weekly" }
    }
}

/// One (timestamp, fraction-used) reading. Fraction is the clamped 0...1 gauge value.
public struct BurnSample: Codable, Sendable, Equatable {
    public let t: Date
    public let f: Double
    public init(t: Date, f: Double) { self.t = t; self.f = f }
}

/// Rolling per-provider, per-lane burn samples — the raw material for burn-down charts.
/// Pure value type: all append/coalesce/prune logic lives here, unit-tested; persistence
/// is the `BurnSampler` shell's job. `UsageHistory` keeps only daily PEAKS, which can't
/// draw a within-window burn line; this store keeps the intraday shape.
public struct BurnHistory: Codable, Sendable, Equatable {
    /// provider id → lane raw value → samples ascending by time.
    public private(set) var samples: [String: [String: [BurnSample]]] = [:]

    /// Keep two weeks — enough for a full weekly lane plus the prior week for context.
    public static let retention: TimeInterval = 14 * 86400
    /// Ignore a reading landing under this many seconds after the previous one (wake/manual
    /// refresh storms) — `refreshIfStale` debounces at 60s, this is the belt to its braces.
    public static let stormGap: TimeInterval = 30
    /// Two fractions within this are "the same reading" for run-length coalescing.
    public static let epsilon = 0.005
    /// Hard per-lane cap (ring backstop) so the store can't grow unbounded even if pruning
    /// somehow never runs. 4096 ≥ 14 days of 5-minute always-changing samples.
    public static let maxPerLane = 4096

    public init() {}

    /// Append one reading. Flat runs are stored as their two endpoints: a repeat of an
    /// already-repeated value slides the tail forward instead of appending, so a steady
    /// meter costs 2 samples however long it idles, and the chart still draws the flat
    /// segment (not a slow ramp between distant points). Returns true when the store changed.
    @discardableResult
    public mutating func record(provider: String, lane: BurnLane, fraction: Double, at now: Date) -> Bool {
        let f = min(max(fraction, 0), 1)
        var arr = samples[provider]?[lane.rawValue] ?? []
        defer { samples[provider, default: [:]][lane.rawValue] = arr }

        guard let last = arr.last else {
            arr.append(BurnSample(t: now, f: f))
            return true
        }
        guard now.timeIntervalSince(last.t) >= Self.stormGap else { return false }
        if abs(f - last.f) < Self.epsilon {
            // Same reading. Second point of a flat run appends (the run needs a start and an
            // end); a third+ slides the existing end forward.
            if arr.count >= 2, abs(arr[arr.count - 2].f - last.f) < Self.epsilon {
                arr[arr.count - 1] = BurnSample(t: now, f: last.f)
            } else {
                arr.append(BurnSample(t: now, f: last.f))
            }
        } else {
            arr.append(BurnSample(t: now, f: f))
        }
        if arr.count > Self.maxPerLane { arr.removeFirst(arr.count - Self.maxPerLane) }
        return true
    }

    /// Drop samples older than the retention window (keeping the newest out-of-window sample
    /// would add nothing — a lane chart never looks back further than retention).
    public mutating func prune(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        for (p, lanes) in samples {
            for (l, arr) in lanes {
                let kept = arr.filter { $0.t >= cutoff }
                if kept.isEmpty { samples[p]?[l] = nil } else if kept.count != arr.count { samples[p]?[l] = kept }
            }
            if samples[p]?.isEmpty == true { samples[p] = nil }
        }
    }

    /// Samples for one provider+lane at/after `since`, ascending.
    public func series(provider: String, lane: BurnLane, since: Date) -> [BurnSample] {
        (samples[provider]?[lane.rawValue] ?? []).filter { $0.t >= since }
    }

    /// Providers that have any samples in a lane — drives the chart's provider picker.
    public func providers(in lane: BurnLane) -> [String] {
        samples.compactMap { (p, lanes) in (lanes[lane.rawValue]?.isEmpty == false) ? p : nil }.sorted()
    }

    /// The tightest authoritative capped fraction per lane for one reading — what `record`
    /// should be fed. Skips unlimited meters, estimates, and windows outside both lanes.
    public static func laneFractions(for usage: ProviderUsage) -> [BurnLane: Double] {
        var out: [BurnLane: Double] = [:]
        for m in usage.metrics where m.authoritative && !m.unlimited {
            guard let lane = BurnLane.lane(forWindowSeconds: m.windowDuration),
                  let f = m.fractionUsed else { continue }
            if f > (out[lane] ?? -1) { out[lane] = f }
        }
        return out
    }
}

/// Persistence shell over `BurnHistory` — loads/saves `burnsamples.json` beside
/// `history.json` in Application Support. Called on every refresh; cheap (append + save
/// only when something changed).
@MainActor
public final class BurnSampler {
    public static let shared = BurnSampler()

    private let fileURL: URL
    public private(set) var history = BurnHistory()

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask, appropriateFor: nil, create: true))
                ?? FileManager.default.homeDirectoryForCurrentUser
            let dir = base.appendingPathComponent("Headroom", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("burnsamples.json")
        }
        load()
    }

    /// Record the current readings. Only `.ok` providers sample — a `.stale` fallback echoes
    /// an old fraction, and recording it would draw a confident flat line over hours of
    /// actually-unknown usage.
    public func record(_ usages: [ProviderUsage], at now: Date = Date()) {
        var changed = false
        for u in usages where u.status == .ok {
            for (lane, f) in BurnHistory.laneFractions(for: u) {
                if history.record(provider: u.id, lane: lane, fraction: f, at: now) { changed = true }
            }
        }
        guard changed else { return }
        history.prune(now: now)
        save()
    }

    public func series(provider: String, lane: BurnLane, hours: Double, now: Date = Date()) -> [BurnSample] {
        history.series(provider: provider, lane: lane, since: now.addingTimeInterval(-hours * 3600))
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let h = try? JSONDecoder().decode(BurnHistory.self, from: data) else { return }
        history = h
    }
    private func save() {
        if let data = try? JSONEncoder().encode(history) { try? data.write(to: fileURL, options: .atomic) }
    }
}
