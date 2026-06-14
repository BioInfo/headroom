import Testing
import Foundation
@testable import HeadroomKit

// Real response shape captured 2026-06-13 from api.anthropic.com/api/oauth/usage
// (see docs/PROVIDERS.md). Null sibling windows must be ignored; extra_usage maps
// only when enabled.
private let claudeUsageJSON = #"""
{"five_hour":{"utilization":30.0,"resets_at":"2026-06-14T02:59:59.160907+00:00"},"seven_day":{"utilization":15.0,"resets_at":"2026-06-17T20:59:59.160933+00:00"},"seven_day_oauth_apps":null,"seven_day_opus":null,"seven_day_sonnet":{"utilization":3.0,"resets_at":"2026-06-17T21:00:00.160945+00:00"},"tangelo":null,"extra_usage":{"is_enabled":true,"monthly_limit":5000,"used_credits":3462.0,"utilization":69.24,"currency":"USD","disabled_reason":null}}
"""#

@Test func claudeDecodesWindowsSkippingNulls() throws {
    let usage = try JSONDecoder().decode(ClaudeCollector.Usage.self,
                                         from: Data(claudeUsageJSON.utf8))
    let m = usage.metrics
    // five_hour, seven_day, seven_day_sonnet — opus is null (dropped); extra_usage is
    // intentionally not surfaced (a $ pool, not headroom).
    #expect(m.count == 3)
    #expect(m.map(\.label) == ["5h window", "Weekly", "Weekly (Sonnet)"])

    let five = m.first { $0.label == "5h window" }
    #expect(five?.percentUsed == 30.0)
    #expect(five?.unit == .percent)
    #expect(five?.fractionUsed == 0.30)
    // microsecond + offset timestamp must parse via the fractional formatter.
    #expect(five?.resetAt != nil)
}

@Test func claudeExtraUsageNotInWindowMetrics() throws {
    // The window metrics never include Extra usage — it's a $ pool, kept out of the
    // default set so it can't hijack the menu-bar glyph.
    let usage = try JSONDecoder().decode(ClaudeCollector.Usage.self,
                                         from: Data(claudeUsageJSON.utf8))
    #expect(usage.metrics.first { $0.label == "Extra usage" } == nil)
}

@Test func claudeExtraUsageMetricOptIn() throws {
    // Opt-in path: extraUsageMetric carries credits + percent when enabled.
    let usage = try JSONDecoder().decode(ClaudeCollector.Usage.self,
                                         from: Data(claudeUsageJSON.utf8))
    let extra = usage.extraUsageMetric
    #expect(extra?.percentUsed == 69.24)
    #expect(extra?.used == 3462.0)
    #expect(extra?.limit == 5000)
    #expect(extra?.unit == .usd)
}

@Test func claudeExtraUsageHiddenWhenDisabled() throws {
    let json = #"{"five_hour":{"utilization":10.0,"resets_at":"2026-06-14T03:00:00.0+00:00"},"extra_usage":{"is_enabled":false,"monthly_limit":5000,"used_credits":0.0,"utilization":0.0}}"#
    let usage = try JSONDecoder().decode(ClaudeCollector.Usage.self, from: Data(json.utf8))
    #expect(usage.metrics.map(\.label) == ["5h window"])
}

@Test func claudeParsesISOWithMicrosecondsAndOffset() {
    let d = ClaudeCollector.parseISO("2026-06-14T02:59:59.160907+00:00")
    #expect(d != nil)
    #expect(ClaudeCollector.parseISO(nil) == nil)
}
