import Foundation

/// One day's token throughput (Claude local logs). `tokens` = input + output + cache.
public struct TokenDay: Codable, Sendable, Identifiable {
    public let day: Date          // local midnight of the day
    public let tokens: Int
    public var id: Date { day }
    public init(day: Date, tokens: Int) { self.day = day; self.tokens = tokens }
}

/// One day's peak utilization per provider (self-recorded from live readings).
public struct DayUtilization: Sendable, Identifiable {
    public let day: Date
    public let fractions: [String: Double]   // provider id → peak fraction 0...1 that day
    public var id: Date { day }
    public var peak: Double? { fractions.values.max() }
}

/// Headroom's own usage history, two layers:
///  1. **Self-recorded** peak utilization per provider per day — uniform across every
///     provider, no extra auth, accrues from first launch. Powers sparklines + the
///     utilization heatmap/trend. Persisted to Application Support.
///  2. **Claude token backfill** — parses the Claude Code local JSONL logs for real daily
///     token throughput (months of history already on disk). Powers the token trend +
///     heatmap that matches the provider dashboards. Read on demand, off the main thread.
///     (Codex/others keep token accounting in sqlite, not clean JSONL → deferred.)
@MainActor
public final class UsageHistory {
    public static let shared = UsageHistory()

    private let fileURL: URL
    /// day "yyyy-MM-dd" → provider id → peak fraction.
    private var store: [String: [String: Double]] = [:]

    private static let dayKey: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask, appropriateFor: nil, create: true))
                ?? FileManager.default.homeDirectoryForCurrentUser
            let dir = base.appendingPathComponent("Headroom", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("history.json")
        }
        load()
    }

    // MARK: - layer 1: self-recorded utilization

    /// Merge today's peak authoritative fraction per provider into the store (keep the max
    /// seen today). Cheap; called on every refresh.
    public func record(_ usages: [ProviderUsage], on date: Date = Date()) {
        let key = Self.dayKey.string(from: date)
        var today = store[key] ?? [:]
        var changed = false
        for u in usages {
            let peak = u.metrics.filter { $0.authoritative }.compactMap { $0.fractionUsed }.max()
            guard let peak else { continue }
            if peak > (today[u.id] ?? -1) { today[u.id] = peak; changed = true }
        }
        guard changed else { return }
        store[key] = today
        save()
    }

    /// Last `days` days of recorded utilization, oldest→newest (only days with data).
    public func utilizationSeries(days: Int = 30) -> [DayUtilization] {
        let cal = Calendar.current
        let cutoff = cal.startOfDay(for: Date()).addingTimeInterval(-Double(days) * 86400)
        return store.compactMap { (k, v) -> DayUtilization? in
            guard let d = Self.dayKey.date(from: k), d >= cutoff else { return nil }
            return DayUtilization(day: d, fractions: v)
        }.sorted { $0.day < $1.day }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let obj = try? JSONDecoder().decode([String: [String: Double]].self, from: data) else { return }
        store = obj
    }
    private func save() {
        if let data = try? JSONEncoder().encode(store) { try? data.write(to: fileURL) }
    }

    // MARK: - layer 2: Claude token backfill (from local JSONL logs)

    /// Sum Claude Code token throughput per local day over the last `days`. Parses only
    /// log files modified within the window (+1 day slack). Off-main: call from a Task.
    public nonisolated static func claudeTokenSeries(days: Int = 90) async -> [TokenDay] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent(".claude/projects", isDirectory: true)
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else {
            return []
        }
        let cal = Calendar.current
        let windowStart = cal.startOfDay(for: Date()).addingTimeInterval(-Double(days) * 86400)
        let fileCutoff = windowStart.addingTimeInterval(-86400)   // a session can straddle midnight

        var totals: [Date: Int] = [:]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        let urls = (en.allObjects as? [URL]) ?? []
        for url in urls {
            guard url.pathExtension == "jsonl" else { continue }
            let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard vals?.isRegularFile == true,
                  let m = vals?.contentModificationDate, m >= fileCutoff else { continue }
            do {
                for try await line in url.lines {
                    guard line.contains("input_tokens"),
                          let data = line.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let ts = obj["timestamp"] as? String,
                          let msg = obj["message"] as? [String: Any],
                          let usage = msg["usage"] as? [String: Any] else { continue }
                    let when = iso.date(from: ts) ?? isoPlain.date(from: ts)
                    guard let when, when >= windowStart else { continue }
                    let day = cal.startOfDay(for: when)
                    let t = (usage["input_tokens"] as? Int ?? 0)
                          + (usage["output_tokens"] as? Int ?? 0)
                          + (usage["cache_creation_input_tokens"] as? Int ?? 0)
                          + (usage["cache_read_input_tokens"] as? Int ?? 0)
                    totals[day, default: 0] += t
                }
            } catch { continue }
        }
        return totals.map { TokenDay(day: $0.key, tokens: $0.value) }.sorted { $0.day < $1.day }
    }
}
