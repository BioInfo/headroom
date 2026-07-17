import Foundation

/// One day's token throughput (Claude local logs). `tokens` = input + output + cache.
public struct TokenDay: Codable, Sendable, Identifiable, Equatable {
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

    /// Extract `(timestamp, tokens)` from one Claude Code transcript JSONL line, or nil if it
    /// isn't a token-bearing record. Pure + testable (no filesystem).
    nonisolated static func parseClaudeTokenLine(_ line: String, iso: ISO8601DateFormatter,
                                                 isoPlain: ISO8601DateFormatter) -> (Date, Int)? {
        guard line.contains("input_tokens"),
              let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ts = obj["timestamp"] as? String,
              let msg = obj["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any] else { return nil }
        guard let when = iso.date(from: ts) ?? isoPlain.date(from: ts) else { return nil }
        let t = (usage["input_tokens"] as? Int ?? 0)
              + (usage["output_tokens"] as? Int ?? 0)
              + (usage["cache_creation_input_tokens"] as? Int ?? 0)
              + (usage["cache_read_input_tokens"] as? Int ?? 0)
        return (when, t)
    }

    /// Sum Claude Code token throughput per local day over the last `days`. Uncached
    /// convenience — the app passes a `TokenScanCache` so repeat scans only parse changed
    /// files. Off-main: call from a Task.
    public nonisolated static func claudeTokenSeries(days: Int = 90) async -> [TokenDay] {
        (await claudeTokenSeries(days: days, cache: TokenScanCache())).series
    }

    /// Cache-aware Claude token scan: reuse each unchanged file's parsed records, re-parse
    /// only new/modified files, and return the updated cache for the caller to persist. The
    /// returned cache contains exactly the files seen this scan (deleted/aged-out entries
    /// fall away).
    public nonisolated static func claudeTokenSeries(days: Int, cache: TokenScanCache,
                                                     roots: [URL]? = nil) async -> (series: [TokenDay], cache: TokenScanCache) {
        let roots = roots ?? [FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)]
        let cal = Calendar.current
        let windowStart = cal.startOfDay(for: Date()).addingTimeInterval(-Double(days) * 86400)
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        var next = TokenScanCache()
        // A session can straddle midnight, so admit files a day older than the window.
        for (url, mtime, size) in SpendUsage.jsonlFilesWithMeta(under: roots,
                                                                modifiedAfter: windowStart.addingTimeInterval(-86400)) {
            if let hit = cache.entry(for: url.path, mtime: mtime, size: size) {
                next.files[url.path] = hit
                continue
            }
            // Parse the whole file (no window filter here — the cache outlives this window;
            // `merged` applies the cutoff).
            var hits: [(when: Date, tokens: Int)] = []
            do {
                for try await line in url.lines {
                    guard let h = parseClaudeTokenLine(line, iso: iso, isoPlain: isoPlain) else { continue }
                    hits.append(h)
                }
            } catch { continue }
            next.files[url.path] = TokenScanCache.FileScan(mtime: mtime.timeIntervalSince1970, size: size,
                                                           recs: TokenScanCache.recs(from: hits, calendar: cal))
        }
        let totals = next.merged(windowStart: windowStart)
        return (totals.map { TokenDay(day: $0.key, tokens: $0.value) }.sorted { $0.day < $1.day }, next)
    }

    // MARK: - layer 2 (cont.): Codex token backfill (from ~/.codex rollout JSONL)

    /// Providers Headroom can backfill *real token* history for, from their local logs.
    /// Claude (`~/.claude/projects/**.jsonl`) and Codex (`~/.codex/sessions/**.jsonl`) both
    /// write per-turn token usage to disk; the key/web providers (MiniMax, GLM, Kimi) expose
    /// no local token store, so they live in the self-recorded *utilization* layer only.
    public static let tokenProviders = ["claude", "codex"]

    /// Token series for any provider that has a local log, oldest→newest. Unknown providers
    /// (no local token store) return empty.
    public nonisolated static func tokenSeries(for provider: String, days: Int = 182) async -> [TokenDay] {
        switch provider {
        case "claude": await claudeTokenSeries(days: days)
        case "codex":  await codexTokenSeries(days: days)
        default:       []
        }
    }

    /// Cache-aware `tokenSeries`. The app uses this so a refresh only parses files that
    /// actually changed — the uncached form re-reads the whole corpus (8+ GB on a heavy
    /// tree) and must never sit on a repeating refresh tick.
    public nonisolated static func tokenSeries(for provider: String, days: Int,
                                               cache: TokenScanCache) async -> (series: [TokenDay], cache: TokenScanCache) {
        switch provider {
        case "claude": await claudeTokenSeries(days: days, cache: cache)
        case "codex":  await codexTokenSeries(days: days, cache: cache)
        default:       ([], cache)
        }
    }

    /// Extract `(timestamp, tokens)` from one Codex rollout JSONL line, or nil if it isn't a
    /// token-bearing event. Each `token_count` event carries `info.last_token_usage` — the
    /// most recent turn's delta — so summing it per day gives daily throughput (the cumulative
    /// `total_token_usage` would double-count). Pure + testable (no filesystem).
    nonisolated static func parseCodexTokenLine(_ line: String, iso: ISO8601DateFormatter,
                                                isoPlain: ISO8601DateFormatter) -> (Date, Int)? {
        guard line.contains("last_token_usage"),
              let data = line.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (o["type"] as? String) == "event_msg",
              let ts = o["timestamp"] as? String,
              let p = o["payload"] as? [String: Any],
              (p["type"] as? String) == "token_count",
              let info = p["info"] as? [String: Any],
              let last = info["last_token_usage"] as? [String: Any],
              let total = last["total_tokens"] as? Int, total > 0 else { return nil }
        guard let when = iso.date(from: ts) ?? isoPlain.date(from: ts) else { return nil }
        return (when, total)
    }

    /// Sum Codex token throughput per local day over the last `days`, from the rollout logs
    /// under `~/.codex/sessions` (+ `archived_sessions`). Mirrors `claudeTokenSeries`: parse
    /// only files modified within the window. Off-main: call from a Task.
    public nonisolated static func codexTokenSeries(days: Int = 182) async -> [TokenDay] {
        (await codexTokenSeries(days: days, cache: TokenScanCache())).series
    }

    /// Cache-aware Codex token scan. Mirrors `claudeTokenSeries(days:cache:roots:)`.
    public nonisolated static func codexTokenSeries(days: Int, cache: TokenScanCache,
                                                    roots: [URL]? = nil) async -> (series: [TokenDay], cache: TokenScanCache) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = roots ?? [home.appendingPathComponent(".codex/sessions", isDirectory: true),
                              home.appendingPathComponent(".codex/archived_sessions", isDirectory: true)]
        let cal = Calendar.current
        let windowStart = cal.startOfDay(for: Date()).addingTimeInterval(-Double(days) * 86400)
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        var next = TokenScanCache()
        for (url, mtime, size) in SpendUsage.jsonlFilesWithMeta(under: roots,
                                                                modifiedAfter: windowStart.addingTimeInterval(-86400)) {
            guard url.lastPathComponent.hasPrefix("rollout-") else { continue }
            if let hit = cache.entry(for: url.path, mtime: mtime, size: size) {
                next.files[url.path] = hit
                continue
            }
            var hits: [(when: Date, tokens: Int)] = []
            do {
                for try await line in url.lines {
                    guard let h = parseCodexTokenLine(line, iso: iso, isoPlain: isoPlain) else { continue }
                    hits.append(h)
                }
            } catch { continue }
            next.files[url.path] = TokenScanCache.FileScan(mtime: mtime.timeIntervalSince1970, size: size,
                                                           recs: TokenScanCache.recs(from: hits, calendar: cal))
        }
        let totals = next.merged(windowStart: windowStart)
        return (totals.map { TokenDay(day: $0.key, tokens: $0.value) }.sorted { $0.day < $1.day }, next)
    }
}
