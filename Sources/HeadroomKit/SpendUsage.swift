import Foundation

/// Per-model token counts split by billing lane (Anthropic/OpenAI semantics differ on what
/// `input` includes — the scanners normalize so each lane is priced independently).
public struct ModelTokens: Equatable, Sendable {
    public var input = 0        // non-cached input tokens
    public var output = 0       // output (incl. reasoning where the provider folds it in)
    public var cacheRead = 0
    public var cacheWrite = 0
    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
    }
    public mutating func add(_ o: ModelTokens) {
        input += o.input; output += o.output; cacheRead += o.cacheRead; cacheWrite += o.cacheWrite
    }
    public var total: Int { input + output + cacheRead + cacheWrite }
}

/// Estimated local spend from a provider's own session logs — the tokens the machine
/// actually pushed, priced at list rates. This is an *estimate of consumption value*, not a
/// bill: subscription plans don't meter per token, logs can be pruned/moved, and unknown
/// models stay unpriced. Labeled "estimated, from local logs" wherever it renders.
public enum SpendUsage {
    /// day (local midnight) → model id → tokens
    public typealias Daily = [Date: [String: ModelTokens]]

    // MARK: - pricing math (pure)

    /// USD for one token bundle at a model's list price (prices are per 1M tokens).
    public static func cost(_ t: ModelTokens, at p: ModelPrice) -> Double {
        (Double(t.input) * p.input + Double(t.output) * p.output
         + Double(t.cacheRead) * p.cacheRead + Double(t.cacheWrite) * p.cacheWrite) / 1_000_000
    }

    /// One model's slice of a spend summary.
    public struct ModelSpend: Equatable, Sendable, Identifiable {
        public let model: String
        public let usd: Double?      // nil = model not in the pricing catalog (unpriced)
        public let tokens: Int
        public var id: String { model }
    }

    /// Windowed totals over a `Daily` aggregation. `today`/`last7`/`last30` are USD over
    /// priced models only; `unpricedTokens` counts what couldn't be priced so the readout
    /// can be honest about coverage.
    public struct Summary: Equatable, Sendable {
        public let today: Double
        public let last7: Double
        public let last30: Double
        public let byModel30: [ModelSpend]   // 30-day slice, largest first
        public let unpricedTokens30: Int
    }

    /// Roll a daily aggregation into Today / 7d / 30d USD + a 30-day per-model breakdown.
    /// Calendar windows: "last 7" = today plus the 6 days before it, missing days count 0.
    public static func summarize(_ daily: Daily, provider: String, pricing: ModelPricing.Table,
                                 now: Date = Date(), calendar: Calendar = .current) -> Summary {
        let today = calendar.startOfDay(for: now)
        let d7 = today.addingTimeInterval(-6 * 86400)
        let d30 = today.addingTimeInterval(-29 * 86400)

        var usdToday = 0.0, usd7 = 0.0, usd30 = 0.0
        var byModel: [String: (usd: Double?, tokens: Int)] = [:]
        var unpriced = 0

        for (day, models) in daily {
            guard day >= d30, day <= today else { continue }
            for (model, tokens) in models {
                let price = ModelPricing.price(provider: provider, model: model, in: pricing)
                let usd = price.map { cost(tokens, at: $0) }
                if let usd {
                    usd30 += usd
                    if day >= d7 { usd7 += usd }
                    if day == today { usdToday += usd }
                } else {
                    unpriced += tokens.total
                }
                var slot = byModel[model] ?? (usd: price != nil ? 0 : nil, tokens: 0)
                if let usd { slot.usd = (slot.usd ?? 0) + usd }
                slot.tokens += tokens.total
                byModel[model] = slot
            }
        }
        let breakdown = byModel.map { ModelSpend(model: $0.key, usd: $0.value.usd, tokens: $0.value.tokens) }
            .sorted { ($0.usd ?? 0, $0.tokens) > ($1.usd ?? 0, $1.tokens) }
        return Summary(today: usdToday, last7: usd7, last30: usd30,
                       byModel30: breakdown, unpricedTokens30: unpriced)
    }

    // MARK: - Claude scanner (per-model, from ~/.claude/projects JSONL)

    /// Parse one Claude log line into (timestamp, model, tokens, dedupeKey), or nil.
    /// Anthropic usage fields are disjoint lanes: `input_tokens` EXCLUDES the cache lanes.
    /// Streamed messages can repeat a message's usage per chunk (cumulative), so callers
    /// dedupe by `message.id + requestId`, keeping the LAST occurrence.
    nonisolated static func parseClaudeSpendLine(_ line: String, iso: ISO8601DateFormatter,
                                                 isoPlain: ISO8601DateFormatter) -> (when: Date, model: String, tokens: ModelTokens, key: String)? {
        guard line.contains("input_tokens"),
              let data = line.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (o["type"] as? String) == "assistant",
              let ts = o["timestamp"] as? String,
              let msg = o["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any] else { return nil }
        guard let when = iso.date(from: ts) ?? isoPlain.date(from: ts) else { return nil }
        let model = (msg["model"] as? String) ?? "unknown"
        let t = ModelTokens(input: usage["input_tokens"] as? Int ?? 0,
                            output: usage["output_tokens"] as? Int ?? 0,
                            cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0,
                            cacheWrite: usage["cache_creation_input_tokens"] as? Int ?? 0)
        guard t.total > 0 else { return nil }
        let key = "\((msg["id"] as? String) ?? UUID().uuidString)|\((o["requestId"] as? String) ?? "")"
        return (when, model, t, key)
    }

    /// Per-model daily tokens from the Claude Code local logs, last `days` days.
    /// Off-main: call from a Task. Uncached convenience — the app and CLI pass a
    /// `SpendScanCache` so repeat scans only parse changed files.
    public nonisolated static func claudeDaily(days: Int = 30) async -> Daily {
        (await claudeDaily(days: days, cache: SpendScanCache())).daily
    }

    /// Cache-aware Claude scan: reuse each unchanged file's parsed records, re-parse only
    /// new/modified files, and return the updated cache for the caller to persist. The
    /// returned cache contains exactly the files seen this scan (deleted/aged-out entries
    /// fall away). Cross-file dedupe happens in `SpendScanCache.merged` — see its header.
    public nonisolated static func claudeDaily(days: Int, cache: SpendScanCache,
                                               roots: [URL]? = nil) async -> (daily: Daily, cache: SpendScanCache) {
        let roots = roots ?? [FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)]
        let cal = Calendar.current
        let windowStart = cal.startOfDay(for: Date()).addingTimeInterval(-Double(days) * 86400)
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        var next = SpendScanCache()
        for (url, mtime, size) in jsonlFilesWithMeta(under: roots, modifiedAfter: windowStart.addingTimeInterval(-86400)) {
            if let hit = cache.entry(for: url.path, mtime: mtime, size: size) {
                next.files[url.path] = hit
                continue
            }
            // Parse the whole file (no window filter here — the cache outlives this window;
            // merge applies the cutoff). Dedupe within the file: last chunk wins per key.
            var latest: [String: (when: Date, model: String, tokens: ModelTokens)] = [:]
            do {
                for try await line in url.lines {
                    guard let hit = parseClaudeSpendLine(line, iso: iso, isoPlain: isoPlain) else { continue }
                    latest[hit.key] = (hit.when, hit.model, hit.tokens)
                }
            } catch { continue }
            var models: [String] = []
            var index: [String: Int] = [:]
            let recs = latest.map { (key, v) -> SpendScanCache.Rec in
                let m = index[v.model] ?? { let i = models.count; models.append(v.model); index[v.model] = i; return i }()
                return SpendScanCache.Rec(h: SpendScanCache.fnv1a(key),
                                          day: cal.startOfDay(for: v.when).timeIntervalSince1970,
                                          m: m, i: v.tokens.input, o: v.tokens.output,
                                          r: v.tokens.cacheRead, w: v.tokens.cacheWrite)
            }
            next.files[url.path] = SpendScanCache.FileScan(mtime: mtime.timeIntervalSince1970,
                                                           size: size, models: models, recs: recs)
        }
        return (next.merged(windowStart: windowStart), next)
    }

    // MARK: - Codex scanner (per-model, from ~/.codex rollout JSONL)

    /// The session's model from a rollout file's head meta record (a payload carrying
    /// `"model"`, before any turns). One model per session file; files without one bucket
    /// as "unknown" and stay unpriced rather than being guessed.
    nonisolated static func parseCodexMetaModel(_ line: String) -> String? {
        guard line.contains("\"model\""),
              let data = line.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let p = o["payload"] as? [String: Any],
              let m = p["model"] as? String, !m.isEmpty else { return nil }
        return m
    }

    /// OpenAI usage semantics: `input_tokens` INCLUDES `cached_input_tokens`; cached bills
    /// at the cache-read rate, the remainder at input rate. `output_tokens` already includes
    /// reasoning. Codex has no cache-write lane.
    nonisolated static func codexTokens(fromLast last: [String: Any]) -> ModelTokens? {
        let input = last["input_tokens"] as? Int ?? 0
        let cached = min(last["cached_input_tokens"] as? Int ?? 0, input)
        let output = last["output_tokens"] as? Int ?? 0
        let t = ModelTokens(input: input - cached, output: output, cacheRead: cached, cacheWrite: 0)
        return t.total > 0 ? t : nil
    }

    /// Per-model daily tokens from the Codex rollout logs, last `days` days.
    /// Off-main: call from a Task. Uncached convenience — see the cache-aware overload.
    public nonisolated static func codexDaily(days: Int = 30) async -> Daily {
        (await codexDaily(days: days, cache: SpendScanCache())).daily
    }

    /// Cache-aware Codex scan (same contract as the Claude overload). Rollouts don't
    /// fork-copy transcripts, so records aggregate per (day, model) with no dedupe hash.
    public nonisolated static func codexDaily(days: Int, cache: SpendScanCache,
                                              roots: [URL]? = nil) async -> (daily: Daily, cache: SpendScanCache) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = roots ?? [home.appendingPathComponent(".codex/sessions", isDirectory: true),
                              home.appendingPathComponent(".codex/archived_sessions", isDirectory: true)]
        let cal = Calendar.current
        let windowStart = cal.startOfDay(for: Date()).addingTimeInterval(-Double(days) * 86400)
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        var next = SpendScanCache()
        for (url, mtime, size) in jsonlFilesWithMeta(under: roots, modifiedAfter: windowStart.addingTimeInterval(-86400))
        where url.lastPathComponent.hasPrefix("rollout-") {
            if let hit = cache.entry(for: url.path, mtime: mtime, size: size) {
                next.files[url.path] = hit
                continue
            }
            var model = "unknown"
            var sawMeta = false
            var perDay: [Date: ModelTokens] = [:]   // one model per session file
            do {
                for try await line in url.lines {
                    if !sawMeta, let m = parseCodexMetaModel(line) { model = m; sawMeta = true }
                    guard line.contains("last_token_usage"),
                          let data = line.data(using: .utf8),
                          let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          (o["type"] as? String) == "event_msg",
                          let ts = o["timestamp"] as? String,
                          let p = o["payload"] as? [String: Any],
                          (p["type"] as? String) == "token_count",
                          let info = p["info"] as? [String: Any],
                          let last = info["last_token_usage"] as? [String: Any],
                          let t = codexTokens(fromLast: last) else { continue }
                    guard let when = iso.date(from: ts) ?? isoPlain.date(from: ts) else { continue }
                    perDay[cal.startOfDay(for: when), default: ModelTokens()].add(t)
                }
            } catch { continue }
            let recs = perDay.map { (day, t) in
                SpendScanCache.Rec(h: nil, day: day.timeIntervalSince1970, m: 0,
                                   i: t.input, o: t.output, r: t.cacheRead, w: t.cacheWrite)
            }
            next.files[url.path] = SpendScanCache.FileScan(mtime: mtime.timeIntervalSince1970,
                                                           size: size, models: [model], recs: recs)
        }
        return (next.merged(windowStart: windowStart), next)
    }

    /// Providers with a local per-model token log → provider id used for pricing lookup.
    public static let providers: [(id: String, pricingProvider: String)] = [
        ("claude", "anthropic"), ("codex", "openai"),
    ]

    // MARK: - shared file walk

    /// JSONL files under `roots` modified after `cutoff`, with the (mtime, size) identity
    /// the scan cache validates against.
    /// Shared with `UsageHistory`'s token scanners, which walk the same trees.
    nonisolated static func jsonlFilesWithMeta(under roots: [URL], modifiedAfter cutoff: Date)
        -> [(url: URL, mtime: Date, size: Int)] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey]
        var out: [(URL, Date, Int)] = []
        for root in roots {
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: keys) else { continue }
            for url in (en.allObjects as? [URL]) ?? [] {
                guard url.pathExtension == "jsonl" else { continue }
                let vals = try? url.resourceValues(forKeys: Set(keys))
                guard vals?.isRegularFile == true,
                      let m = vals?.contentModificationDate, m >= cutoff else { continue }
                out.append((url, m, vals?.fileSize ?? 0))
            }
        }
        return out
    }
}
