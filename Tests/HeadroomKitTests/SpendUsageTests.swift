import Testing
import Foundation
@testable import HeadroomKit

// Trimmed real shape from models.dev/api.json (captured 2026-07-16): provider → models →
// cost in USD per 1M tokens. Includes a dated and an undated id to lock the fallback rules.
private let pricingJSON = #"""
{"anthropic":{"id":"anthropic","models":{
  "claude-opus-4-8":{"id":"claude-opus-4-8","cost":{"input":5,"output":25,"cache_read":0.5,"cache_write":6.25}},
  "claude-haiku-4-5":{"id":"claude-haiku-4-5","cost":{"input":1,"output":5,"cache_read":0.1,"cache_write":1.25}},
  "free-model":{"id":"free-model"}}},
 "openai":{"id":"openai","models":{
  "gpt-5.5-20260101":{"id":"gpt-5.5-20260101","cost":{"input":2,"output":8,"cache_read":0.25}}}}}
"""#

private var table: ModelPricing.Table { ModelPricing.parse(Data(pricingJSON.utf8)) }

@Test func pricingParsesProviderScopedCosts() {
    let t = table
    #expect(t["anthropic"]?["claude-opus-4-8"] == ModelPrice(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25))
    #expect(t["anthropic"]?["free-model"] == nil)          // no cost object → unpriced
    #expect(t["openai"]?["gpt-5.5-20260101"]?.cacheWrite == 0)   // missing component → 0
}

@Test func pricingLookupHandlesDateSuffixBothWays() {
    let t = table
    // log has dated id, catalog has undated
    #expect(ModelPricing.price(provider: "anthropic", model: "claude-haiku-4-5-20251001", in: t)?.input == 1)
    // log has undated id, catalog has dated
    #expect(ModelPricing.price(provider: "openai", model: "gpt-5.5", in: t)?.input == 2)
    // exact match wins, wrong provider misses
    #expect(ModelPricing.price(provider: "anthropic", model: "claude-opus-4-8", in: t)?.output == 25)
    #expect(ModelPricing.price(provider: "openai", model: "claude-opus-4-8", in: t) == nil)
}

@Test func spendCostMath() {
    let p = ModelPrice(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25)
    // 1M of each lane = 5 + 25 + 0.5 + 6.25
    let t = ModelTokens(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000, cacheWrite: 1_000_000)
    #expect(SpendUsage.cost(t, at: p) == 36.75)
    #expect(SpendUsage.cost(ModelTokens(), at: p) == 0)
}

@Test func claudeSpendLineParsesLanesAndDedupeKey() {
    let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let line = #"{"type":"assistant","timestamp":"2026-07-14T16:18:33.758Z","requestId":"req_1","message":{"id":"msg_1","model":"claude-haiku-4-5-20251001","usage":{"input_tokens":10,"cache_creation_input_tokens":79529,"cache_read_input_tokens":7,"output_tokens":243}}}"#
    let hit = SpendUsage.parseClaudeSpendLine(line, iso: iso, isoPlain: ISO8601DateFormatter())
    #expect(hit?.model == "claude-haiku-4-5-20251001")
    // Anthropic lanes are disjoint: input EXCLUDES the cache lanes.
    #expect(hit?.tokens == ModelTokens(input: 10, output: 243, cacheRead: 7, cacheWrite: 79529))
    #expect(hit?.key == "msg_1|req_1")
    // non-assistant lines don't count
    let user = #"{"type":"user","timestamp":"2026-07-14T16:18:33.758Z","message":{"usage":{"input_tokens":5}}}"#
    #expect(SpendUsage.parseClaudeSpendLine(user, iso: iso, isoPlain: ISO8601DateFormatter()) == nil)
}

@Test func codexTokensSplitCachedFromInput() {
    // OpenAI semantics: input INCLUDES cached; price the remainder at input rate.
    let t = SpendUsage.codexTokens(fromLast: ["input_tokens": 20087, "cached_input_tokens": 17792,
                                              "output_tokens": 163, "reasoning_output_tokens": 143,
                                              "total_tokens": 20250])
    #expect(t == ModelTokens(input: 2295, output: 163, cacheRead: 17792, cacheWrite: 0))
    // cached can't exceed input; zero-token frames are skipped
    #expect(SpendUsage.codexTokens(fromLast: ["input_tokens": 0, "cached_input_tokens": 0, "output_tokens": 0]) == nil)
}

@Test func codexMetaModelFromHeadRecord() {
    let meta = #"{"timestamp":"2026-07-15T06:40:42.019Z","type":"session_meta","payload":{"model":"gpt-5.5","comp_hash":"2911"}}"#
    #expect(SpendUsage.parseCodexMetaModel(meta) == "gpt-5.5")
    #expect(SpendUsage.parseCodexMetaModel(#"{"payload":{"type":"token_count"}}"#) == nil)
}

@Test func spendSummaryWindowsAndBreakdown() {
    let cal = Calendar.current
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let today = cal.startOfDay(for: now)
    func day(_ back: Int) -> Date { today.addingTimeInterval(-Double(back) * 86400) }

    // 1M input tokens of opus ($5) today, 1M haiku input ($1) 10 days ago (in 30d, not 7d),
    // 1M of an unknown model 3 days ago (unpriced), 1M opus 40 days ago (outside every window).
    let daily: SpendUsage.Daily = [
        day(0):  ["claude-opus-4-8": ModelTokens(input: 1_000_000)],
        day(10): ["claude-haiku-4-5": ModelTokens(input: 1_000_000)],
        day(3):  ["mystery-model": ModelTokens(input: 1_000_000)],
        day(40): ["claude-opus-4-8": ModelTokens(input: 1_000_000)],
    ]
    let s = SpendUsage.summarize(daily, provider: "anthropic", pricing: table, now: now, calendar: cal)
    #expect(s.today == 5)
    #expect(s.last7 == 5)          // the unpriced model adds no USD
    #expect(s.last30 == 6)         // opus today + haiku day-10; day-40 excluded
    #expect(s.unpricedTokens30 == 1_000_000)
    #expect(s.byModel30.first?.model == "claude-opus-4-8")
    #expect(s.byModel30.first { $0.model == "mystery-model" }?.usd == nil)
}
