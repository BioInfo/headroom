import Foundation

/// Per-file parse cache for the spend scanners. A cold 30-day scan of a heavy `~/.claude`
/// tree is ~70s of JSONL parsing; almost all of those files never change again, so each
/// file's parsed contribution is cached keyed by (mtime, size) and only changed/new files
/// re-parse. Warm scans come back in seconds.
///
/// Claude sessions FORK (a resumed session file re-includes the prior transcript, usage
/// records and all), so the file fragments can overlap. Each Claude record therefore
/// carries a stable 64-bit hash of its dedupe key (`message.id|requestId`) and the merge
/// counts every hash once across all files — the same global last-chunk-wins dedupe the
/// uncached scanner did, made cache-shaped. A duplicated message's final usage is identical
/// in every file that carries it, so "which copy wins" doesn't matter. Codex rollouts don't
/// fork-copy; their records aggregate per (day, model) with no hash (`h == nil` = always count).
public struct SpendScanCache: Codable, Sendable, Equatable {
    /// One (day, model, tokens) contribution from a file.
    public struct Rec: Codable, Sendable, Equatable {
        public var h: UInt64?    // dedupe hash; nil = always counts
        public var day: Double   // epoch seconds of local midnight (at parse time)
        public var m: Int        // index into FileScan.models
        public var i: Int, o: Int, r: Int, w: Int
        public init(h: UInt64?, day: Double, m: Int, i: Int, o: Int, r: Int, w: Int) {
            self.h = h; self.day = day; self.m = m; self.i = i; self.o = o; self.r = r; self.w = w
        }
        public var tokens: ModelTokens { ModelTokens(input: i, output: o, cacheRead: r, cacheWrite: w) }
    }

    /// A file's parsed contribution + the identity that validates it.
    public struct FileScan: Codable, Sendable, Equatable {
        public var mtime: Double
        public var size: Int
        public var models: [String]
        public var recs: [Rec]
        public init(mtime: Double, size: Int, models: [String], recs: [Rec]) {
            self.mtime = mtime; self.size = size; self.models = models; self.recs = recs
        }
    }

    /// file path → its parsed scan. Rebuilt each scan from the files actually present, so
    /// deleted/aged-out files fall away without a separate prune.
    public var files: [String: FileScan]

    public init(files: [String: FileScan] = [:]) { self.files = files }

    /// A cached entry is valid for a file iff mtime AND size both match (a same-second
    /// rewrite that changes length still invalidates).
    public func entry(for path: String, mtime: Date, size: Int) -> FileScan? {
        guard let e = files[path], e.mtime == mtime.timeIntervalSince1970, e.size == size else { return nil }
        return e
    }

    /// Merge every file's records into a daily aggregation, counting each dedupe hash once
    /// across all files and dropping records before `windowStart`.
    public func merged(windowStart: Date) -> SpendUsage.Daily {
        var seen = Set<UInt64>()
        var daily: SpendUsage.Daily = [:]
        // Deterministic file order so a hash collision (astronomically unlikely) at least
        // resolves the same way every scan.
        for (_, f) in files.sorted(by: { $0.key < $1.key }) {
            for rec in f.recs {
                let day = Date(timeIntervalSince1970: rec.day)
                guard day >= windowStart else { continue }
                if let h = rec.h { guard seen.insert(h).inserted else { continue } }
                guard f.models.indices.contains(rec.m) else { continue }
                daily[day, default: [:]][f.models[rec.m], default: ModelTokens()].add(rec.tokens)
            }
        }
        return daily
    }

    /// FNV-1a 64 — a stable hash across processes and runs (Swift's `Hasher` is per-process
    /// seeded, useless for a persisted dedupe key).
    public static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return h
    }

    // MARK: - persistence (Application Support/Headroom/spendcache-<provider>.json)

    public static func url(provider: String) -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("Headroom", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("spendcache-\(provider).json")
    }

    public static func load(provider: String) -> SpendScanCache {
        guard let data = try? Data(contentsOf: url(provider: provider)),
              let c = try? JSONDecoder().decode(SpendScanCache.self, from: data) else {
            return SpendScanCache()
        }
        return c
    }

    public func save(provider: String) {
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: Self.url(provider: provider), options: .atomic)
        }
    }
}
