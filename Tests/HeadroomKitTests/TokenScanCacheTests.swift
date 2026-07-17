import Testing
import Foundation
@testable import HeadroomKit

/// The token-history scanners had no cache and re-read the whole corpus on every refresh
/// tick (8.56 GB on a real tree), which pegged a core indefinitely. These lock the cache
/// contract that fixed it: unchanged files are never re-parsed, and caching does not change
/// the numbers.
@Suite("Token scan cache")
struct TokenScanCacheTests {
    let cal = Calendar.current
    var today: Date { cal.startOfDay(for: Date()) }

    // MARK: pure pieces

    @Test func mergeSumsAcrossFilesAndHonorsWindow() {
        let day = today.timeIntervalSince1970
        let old = today.addingTimeInterval(-10 * 86400).timeIntervalSince1970
        let cache = TokenScanCache(files: [
            "/a.jsonl": .init(mtime: 1, size: 1, recs: [.init(day: day, t: 100), .init(day: old, t: 999)]),
            "/b.jsonl": .init(mtime: 1, size: 1, recs: [.init(day: day, t: 5)]),
        ])
        // Unlike the spend cache, history has no dedupe hash — every file's records count.
        #expect(cache.merged(windowStart: .distantPast)[today] == 105)
        // Records older than the window are dropped at merge, not at parse.
        #expect(cache.merged(windowStart: today)[Date(timeIntervalSince1970: old)] == nil)
        #expect(cache.merged(windowStart: today)[today] == 105)
    }

    @Test func recsCollapsePerLocalDay() {
        let noon = today.addingTimeInterval(12 * 3600)
        let recs = TokenScanCache.recs(from: [(noon, 10), (noon.addingTimeInterval(60), 5),
                                              (today.addingTimeInterval(-86400), 7)], calendar: cal)
        #expect(recs.count == 2)                                  // one Rec per day, not per hit
        #expect(recs.first(where: { $0.day == today.timeIntervalSince1970 })?.t == 15)
    }

    @Test func entryInvalidatesOnMtimeOrSize() {
        let m = Date(timeIntervalSince1970: 1000)
        let cache = TokenScanCache(files: ["/a.jsonl": .init(mtime: 1000, size: 50, recs: [])])
        #expect(cache.entry(for: "/a.jsonl", mtime: m, size: 50) != nil)
        #expect(cache.entry(for: "/a.jsonl", mtime: m, size: 51) == nil)                        // grew
        #expect(cache.entry(for: "/a.jsonl", mtime: Date(timeIntervalSince1970: 1001), size: 50) == nil)
        #expect(cache.entry(for: "/missing.jsonl", mtime: m, size: 50) == nil)
    }

    @Test func roundTripsThroughJSON() throws {
        let c = TokenScanCache(files: ["/a.jsonl": .init(mtime: 12.5, size: 3, recs: [.init(day: 100, t: 7)])])
        let back = try JSONDecoder().decode(TokenScanCache.self, from: JSONEncoder().encode(c))
        #expect(back == c)
    }

    // MARK: the scan (the thing that was burning the CPU)

    private func claudeLine(when: Date, input: Int, output: Int) -> String {
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return #"{"type":"assistant","timestamp":"\#(iso.string(from: when))","message":{"id":"m","model":"claude-opus-4-8","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#
    }

    @Test func claudeTokenScanReusesUnchangedFilesAndMatchesUncached() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("headroom-tokencache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let when = today.addingTimeInterval(3600)
        let a = dir.appendingPathComponent("a.jsonl")
        try [claudeLine(when: when, input: 10, output: 5),
             claudeLine(when: when, input: 7, output: 3)]
            .joined(separator: "\n").write(to: a, atomically: true, encoding: .utf8)
        let b = dir.appendingPathComponent("b.jsonl")
        try claudeLine(when: when, input: 1, output: 1).write(to: b, atomically: true, encoding: .utf8)

        // Cold scan.
        let (s1, cache1) = await UsageHistory.claudeTokenSeries(days: 30, cache: TokenScanCache(), roots: [dir])
        #expect(s1.first(where: { $0.day == today })?.tokens == 27)   // 15 + 10 + 2
        #expect(cache1.files.count == 2)

        // Warm scan: byte-identical cache (every file was a hit) and identical series.
        let (s2, cache2) = await UsageHistory.claudeTokenSeries(days: 30, cache: cache1, roots: [dir])
        #expect(s2 == s1)
        #expect(cache2 == cache1)

        // Append to A → only A re-parses; B's entry is reused verbatim.
        try [claudeLine(when: when, input: 10, output: 5),
             claudeLine(when: when, input: 7, output: 3),
             claudeLine(when: when, input: 20, output: 10)]
            .joined(separator: "\n").write(to: a, atomically: true, encoding: .utf8)
        let (s3, cache3) = await UsageHistory.claudeTokenSeries(days: 30, cache: cache2, roots: [dir])
        #expect(s3.first(where: { $0.day == today })?.tokens == 57)   // + 30
        #expect(cache3.files[b.path] == cache2.files[b.path])

        // The cached path must agree with the uncached convenience form.
        let uncached = await UsageHistory.claudeTokenSeries(days: 30, cache: TokenScanCache(), roots: [dir])
        #expect(uncached.series == s3)
    }

    @Test func codexTokenScanOnlyReadsRolloutFiles() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("headroom-tokencache-cx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = iso.string(from: today.addingTimeInterval(3600))
        let line = #"{"type":"event_msg","timestamp":"\#(ts)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":42}}}}"#
        // A rollout file counts; a same-shaped non-rollout file must be ignored.
        try line.write(to: dir.appendingPathComponent("rollout-1.jsonl"), atomically: true, encoding: .utf8)
        try line.write(to: dir.appendingPathComponent("notes.jsonl"), atomically: true, encoding: .utf8)

        let (s, cache) = await UsageHistory.codexTokenSeries(days: 30, cache: TokenScanCache(), roots: [dir])
        #expect(s.first(where: { $0.day == today })?.tokens == 42)
        #expect(cache.files.count == 1)
    }
}
