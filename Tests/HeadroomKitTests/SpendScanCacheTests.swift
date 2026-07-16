import Testing
import Foundation
@testable import HeadroomKit

@Suite("Spend scan cache")
struct SpendScanCacheTests {
    let cal = Calendar.current
    var today: Date { cal.startOfDay(for: Date()) }

    // MARK: pure pieces

    @Test func fnv1aIsStable() {
        // Known FNV-1a 64 vectors — the persisted dedupe key must never drift across runs.
        #expect(SpendScanCache.fnv1a("") == 0xcbf29ce484222325)
        #expect(SpendScanCache.fnv1a("a") == 0xaf63dc4c8601ec8c)
        #expect(SpendScanCache.fnv1a("msg_1|req_1") == SpendScanCache.fnv1a("msg_1|req_1"))
    }

    @Test func mergeCountsHashedRecordOnceAcrossFiles() {
        // The same forked-session message (same hash) in two files counts once; the
        // hashless Codex-style records always count.
        let day = today.timeIntervalSince1970
        let dup = SpendScanCache.Rec(h: 42, day: day, m: 0, i: 100, o: 50, r: 0, w: 0)
        let plain = SpendScanCache.Rec(h: nil, day: day, m: 0, i: 10, o: 5, r: 0, w: 0)
        let cache = SpendScanCache(files: [
            "/a.jsonl": .init(mtime: 1, size: 1, models: ["opus"], recs: [dup, plain]),
            "/b.jsonl": .init(mtime: 1, size: 1, models: ["opus"], recs: [dup, plain]),
        ])
        let daily = cache.merged(windowStart: .distantPast)
        let t = daily[today]!["opus"]!
        #expect(t.input == 120)   // 100 once + 10 twice
        #expect(t.output == 60)   // 50 once + 5 twice
    }

    @Test func mergeAppliesWindowCutoff() {
        let old = SpendScanCache.Rec(h: nil, day: today.addingTimeInterval(-40 * 86400).timeIntervalSince1970,
                                     m: 0, i: 999, o: 0, r: 0, w: 0)
        let recent = SpendScanCache.Rec(h: nil, day: today.timeIntervalSince1970, m: 0, i: 1, o: 0, r: 0, w: 0)
        let cache = SpendScanCache(files: ["/a.jsonl": .init(mtime: 1, size: 1, models: ["m"], recs: [old, recent])])
        let daily = cache.merged(windowStart: today.addingTimeInterval(-30 * 86400))
        #expect(daily.count == 1)
        #expect(daily[today]!["m"]!.input == 1)
    }

    @Test func entryValidatesMtimeAndSize() {
        let scan = SpendScanCache.FileScan(mtime: 100, size: 10, models: [], recs: [])
        let cache = SpendScanCache(files: ["/a.jsonl": scan])
        #expect(cache.entry(for: "/a.jsonl", mtime: Date(timeIntervalSince1970: 100), size: 10) != nil)
        #expect(cache.entry(for: "/a.jsonl", mtime: Date(timeIntervalSince1970: 101), size: 10) == nil)
        #expect(cache.entry(for: "/a.jsonl", mtime: Date(timeIntervalSince1970: 100), size: 11) == nil)
        #expect(cache.entry(for: "/missing.jsonl", mtime: Date(timeIntervalSince1970: 100), size: 10) == nil)
    }

    // MARK: end-to-end over real files (temp dir)

    private func claudeLine(id: String, req: String, model: String, when: Date,
                            input: Int, output: Int) -> String {
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return #"{"type":"assistant","timestamp":"\#(iso.string(from: when))","requestId":"\#(req)","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#
    }

    @Test func claudeScanCachesUnchangedFilesAndDedupesForks() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("headroom-spendcache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let when = today.addingTimeInterval(3600)
        // Session A: two messages, one of them streamed twice (cumulative — last wins).
        let a = dir.appendingPathComponent("a.jsonl")
        try [claudeLine(id: "m1", req: "r1", model: "claude-opus-4-8", when: when, input: 10, output: 5),
             claudeLine(id: "m1", req: "r1", model: "claude-opus-4-8", when: when, input: 100, output: 50),
             claudeLine(id: "m2", req: "r2", model: "claude-opus-4-8", when: when, input: 7, output: 3)]
            .joined(separator: "\n").write(to: a, atomically: true, encoding: .utf8)
        // Session B: a FORK of A — re-includes m1 with its final usage, adds m3.
        let b = dir.appendingPathComponent("b.jsonl")
        try [claudeLine(id: "m1", req: "r1", model: "claude-opus-4-8", when: when, input: 100, output: 50),
             claudeLine(id: "m3", req: "r3", model: "claude-opus-4-8", when: when, input: 1, output: 1)]
            .joined(separator: "\n").write(to: b, atomically: true, encoding: .utf8)

        let (daily1, cache1) = await SpendUsage.claudeDaily(days: 30, cache: SpendScanCache(), roots: [dir])
        let t1 = daily1[today]!["claude-opus-4-8"]!
        #expect(t1.input == 108)    // 100 (m1 deduped across chunks AND files) + 7 + 1
        #expect(t1.output == 54)
        #expect(cache1.files.count == 2)

        // Second scan with the cache: identical result (cache hits, no re-parse drift).
        let (daily2, cache2) = await SpendUsage.claudeDaily(days: 30, cache: cache1, roots: [dir])
        #expect(daily2[today]!["claude-opus-4-8"]! == t1)
        #expect(cache2 == cache1)

        // Append to A (mtime/size change) → only A re-parses; totals pick up the new message.
        try [claudeLine(id: "m1", req: "r1", model: "claude-opus-4-8", when: when, input: 100, output: 50),
             claudeLine(id: "m2", req: "r2", model: "claude-opus-4-8", when: when, input: 7, output: 3),
             claudeLine(id: "m4", req: "r4", model: "claude-opus-4-8", when: when, input: 20, output: 10)]
            .joined(separator: "\n").write(to: a, atomically: true, encoding: .utf8)
        let (daily3, cache3) = await SpendUsage.claudeDaily(days: 30, cache: cache2, roots: [dir])
        let t3 = daily3[today]!["claude-opus-4-8"]!
        #expect(t3.input == 128)    // + m4's 20
        #expect(cache3.files[b.path] == cache2.files[b.path])   // untouched file: entry reused as-is
    }

    @Test func codexScanAggregatesPerDayAndCaches() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("headroom-codexcache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let when = today.addingTimeInterval(3600)
        let f = dir.appendingPathComponent("rollout-1.jsonl")
        let meta = #"{"type":"session_meta","payload":{"model":"gpt-5.2"}}"#
        func turn(_ input: Int, _ cached: Int, _ output: Int) -> String {
            #"{"type":"event_msg","timestamp":"\#(iso.string(from: when))","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output)}}}}"#
        }
        try [meta, turn(100, 40, 20), turn(50, 0, 10)].joined(separator: "\n")
            .write(to: f, atomically: true, encoding: .utf8)

        let (daily1, cache1) = await SpendUsage.codexDaily(days: 30, cache: SpendScanCache(), roots: [dir])
        let t = daily1[today]!["gpt-5.2"]!
        #expect(t.input == 110)      // (100-40) + 50 — cached split out of input
        #expect(t.cacheRead == 40)
        #expect(t.output == 30)

        let (daily2, cache2) = await SpendUsage.codexDaily(days: 30, cache: cache1, roots: [dir])
        #expect(daily2[today]!["gpt-5.2"]! == t)
        #expect(cache2 == cache1)
    }

    @Test func cacheCodableRoundTrip() throws {
        let rec = SpendScanCache.Rec(h: 7, day: 1_760_000_000, m: 0, i: 1, o: 2, r: 3, w: 4)
        let cache = SpendScanCache(files: ["/x.jsonl": .init(mtime: 9, size: 8, models: ["m"], recs: [rec])])
        let back = try JSONDecoder().decode(SpendScanCache.self, from: JSONEncoder().encode(cache))
        #expect(back == cache)
    }
}
