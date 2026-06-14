import Testing
import Foundation
@testable import HeadroomKit

// Real GetUsages response captured 2026-06-14 from
// kimi.gateway.billing.v1.BillingService/GetUsages (scope FEATURE_CODING), Bearer-only
// (no cookie — verified credentials:"omit" → 200). Values are counts out of limit "100",
// i.e. already percentages; resetTime is ISO-8601 with microseconds + Z.
private let kimiUsagesJSON = """
{"usages":[{"scope":"FEATURE_CODING",
  "detail":{"limit":"100","used":"18","remaining":"82","resetTime":"2026-06-16T15:07:27.898421Z"},
  "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
    "detail":{"limit":"100","used":"39","remaining":"61","resetTime":"2026-06-14T14:07:27.898421Z"}}]}],
 "totalQuota":{"limit":"100","used":"34","remaining":"66"}}
"""

@Test func kimiParsesUsagesIntoMetrics() throws {
    let usage = KimiCollector.parse(Data(kimiUsagesJSON.utf8), id: "kimi", displayName: "Kimi", plan: "Allegretto")
    #expect(usage.status == .ok)
    #expect(usage.plan == "Allegretto")
    #expect(usage.metrics.count == 2)

    let fiveH = usage.metrics[0]
    #expect(fiveH.label == "5h window")
    #expect(fiveH.percentUsed == 39)
    #expect(fiveH.unit == .percent)
    #expect(fiveH.windowDuration == 18000)   // 300 min → drives the pace tick
    #expect(fiveH.resetAt != nil)
    #expect(fiveH.fractionUsed == 0.39)

    let plan = usage.metrics[1]
    #expect(plan.label == "Plan window")
    #expect(plan.percentUsed == 18)
    #expect(plan.windowDuration == nil)       // no fixed length → no even-burn line
    #expect(plan.resetAt != nil)
}

@Test func kimiEmptyResponseIsError() throws {
    let usage = KimiCollector.parse(Data(#"{"usages":[]}"#.utf8), id: "kimi", displayName: "Kimi", plan: nil)
    #expect(usage.status == .error)
}
