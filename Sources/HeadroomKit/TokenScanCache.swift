import Foundation

/// Per-file parse cache for the token-history scanners — the history-side counterpart to
/// `SpendScanCache`.
///
/// ## Why this exists
/// `UsageHistory.claudeTokenSeries`/`codexTokenSeries` walk the same local JSONL logs the
/// spend scanners do, but over a *182-day* window rather than 30. Uncached, that re-parsed
/// the entire corpus on launch AND on every refresh tick (measured on a heavy tree:
/// 12,508 files / 8.56 GB, pegging a core indefinitely — the `warmHistory` doc comment
/// claimed it "only reads log files modified in the window", which is true and meaningless
/// when the window is half a year). Almost every one of those files is finished and will
/// never change again, so each file's parsed contribution is cached keyed by (mtime, size)
/// and only changed/new files re-parse.
///
/// ## Shape
/// A file's records are pre-aggregated per local day at parse time (one `Rec` per day, not
/// per message), which keeps the persisted cache small.
///
/// ## Deliberately NOT deduped
/// Claude sessions fork — a resumed session file re-includes the prior transcript, usage
/// records and all — so `SpendScanCache` carries a per-record hash and counts each key once.
/// The token-history scanners never did that, and this cache is faithful to the behaviour it
/// replaces rather than silently restating a user's history numbers. That means the Claude
/// token series can over-count forked sessions; fixing it is a separate, numbers-changing
/// call. See the note in `UsageHistory`.
public struct TokenScanCache: Codable, Sendable, Equatable {
    /// One day's token total contributed by a single file.
    public struct Rec: Codable, Sendable, Equatable {
        public var day: Double   // epoch seconds of local midnight (at parse time)
        public var t: Int        // total tokens that day, from this file
        public init(day: Double, t: Int) { self.day = day; self.t = t }
    }

    /// A file's parsed contribution + the identity that validates it.
    public struct FileScan: Codable, Sendable, Equatable {
        public var mtime: Double
        public var size: Int
        public var recs: [Rec]
        public init(mtime: Double, size: Int, recs: [Rec]) {
            self.mtime = mtime; self.size = size; self.recs = recs
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

    /// Sum every file's per-day records, dropping days before `windowStart`. Records are
    /// cached unfiltered (the cache outlives any one window), so the cutoff applies here.
    public func merged(windowStart: Date) -> [Date: Int] {
        var out: [Date: Int] = [:]
        for (_, f) in files {
            for rec in f.recs {
                let day = Date(timeIntervalSince1970: rec.day)
                guard day >= windowStart else { continue }
                out[day, default: 0] += rec.t
            }
        }
        return out
    }

    /// Collapse a file's `(when, tokens)` hits into one `Rec` per local day.
    public static func recs(from hits: [(when: Date, tokens: Int)], calendar: Calendar) -> [Rec] {
        var byDay: [Double: Int] = [:]
        for h in hits { byDay[calendar.startOfDay(for: h.when).timeIntervalSince1970, default: 0] += h.tokens }
        return byDay.map { Rec(day: $0.key, t: $0.value) }.sorted { $0.day < $1.day }
    }

    // MARK: - persistence (Application Support/Headroom/tokencache-<provider>.json)

    public static func url(provider: String) -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("Headroom", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tokencache-\(provider).json")
    }

    public static func load(provider: String) -> TokenScanCache {
        guard let data = try? Data(contentsOf: url(provider: provider)),
              let c = try? JSONDecoder().decode(TokenScanCache.self, from: data) else {
            return TokenScanCache()
        }
        return c
    }

    public func save(provider: String) {
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: Self.url(provider: provider), options: .atomic)
        }
    }
}
