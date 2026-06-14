import Testing
import Foundation
@testable import HeadroomKit

// Real response captured 2026-06-13 from api.minimax.io/v1/token_plan/remains with
// the coding-plan key (see docs/PROVIDERS.md). `general` = the text/coding plan;
// `*_remaining_percent` is REMAINING (so used = 100 - it); times are epoch ms.
private let remainsJSON = #"""
{"model_remains":[{"start_time":1781395200000,"end_time":1781413200000,"remains_time":10572400,"current_interval_total_count":0,"current_interval_usage_count":0,"model_name":"general","current_weekly_total_count":0,"current_weekly_usage_count":0,"weekly_start_time":1780876800000,"weekly_end_time":1781481600000,"weekly_remains_time":78972400,"current_interval_status":1,"current_interval_remaining_percent":98,"current_weekly_status":3,"current_weekly_remaining_percent":100},{"start_time":1781395200000,"end_time":1781481600000,"model_name":"video","weekly_start_time":1780876800000,"weekly_end_time":1781481600000,"current_interval_remaining_percent":100,"current_weekly_remaining_percent":100}],"base_resp":{"status_code":0,"status_msg":"success"}}
"""#

@Test func minimaxParsesGeneralWindows() throws {
    let usage = MiniMaxCollector.parse(Data(remainsJSON.utf8), id: "minimax", displayName: "MiniMax")
    #expect(usage.status == .ok)
    #expect(usage.plan == "Coding")
    // Only the `general` model surfaces (coding plan); `video` is dropped in v1.
    #expect(usage.metrics.map(\.label) == ["5h window", "weekly"])

    let five = usage.metrics.first { $0.label == "5h window" }
    let week = usage.metrics.first { $0.label == "weekly" }
    // remaining 98 → used 2 (limited 5h window)
    #expect(five?.percentUsed == 2)
    #expect(five?.unlimited == false)
    // weekly status 3 = uncapped on the coding plan → Unlimited, not a 0% bar
    #expect(week?.unlimited == true)
    #expect(week?.percentUsed == nil)
    #expect(week?.fractionUsed == nil)        // excluded from gauges/tightest
    // end_time is epoch MS → reset Date (limited window only)
    #expect(five?.resetAt.map { Int($0.timeIntervalSince1970) } == 1781413200)
    // 5h interval window length derived from start/end (18000s)
    #expect(five?.windowDuration == 18000)
}

@Test func minimaxInvalidKeyIsNeedsLogin() throws {
    let json = #"{"base_resp":{"status_code":2049,"status_msg":"invalid api key"}}"#
    let usage = MiniMaxCollector.parse(Data(json.utf8), id: "minimax", displayName: "MiniMax")
    #expect(usage.status == .needsLogin)
}

@Test func minimaxBusinessErrorIsError() throws {
    let json = #"{"base_resp":{"status_code":1004,"status_msg":"auth failed"}}"#
    let usage = MiniMaxCollector.parse(Data(json.utf8), id: "minimax", displayName: "MiniMax")
    #expect(usage.status == .error)
}
