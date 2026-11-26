import Testing
import Foundation
@testable import HeadroomKit

// Real `GET /coding/v1/usages` response captured 2026-08-27, API-key auth (no cookie, no
// session JWT). Identifiers scrubbed. Values are counts out of limit "100", i.e. already
// percentages; resetTime is ISO-8601 with microseconds + Z.
// The 5h window is deliberately at 100 here — that is what the live account read, and an
// exhausted sub-window must still parse rather than falling to .error.
private let kimiUsagesJSON = """
{"user":{"userId":"REDACTED","region":"REGION_OVERSEA","membership":{"level":"LEVEL_INTERMEDIATE"},"businessId":""},
 "limited":true,
 "usage":{"limit":"100","used":"45","remaining":"55","resetTime":"2026-09-01T15:07:27.898421Z"},
 "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
   "detail":{"limit":"100","used":"100","resetTime":"2026-08-27T13:07:27.898421Z"}}],
 "parallel":{"limit":"20"},
 "totalQuota":{},
 "authentication":{"method":"METHOD_API_KEY","scope":"FEATURE_CODING"},
 "subType":"TYPE_PURCHASE","domain":"DOMAIN_NEXUS"}
"""

@Test func kimiParsesUsagesIntoMetrics() throws {
    let usage = KimiCollector.parse(Data(kimiUsagesJSON.utf8), id: "kimi", displayName: "Kimi", plan: "Allegretto")
    #expect(usage.status == .ok)
    #expect(usage.plan == "Allegretto")
    #expect(usage.metrics.count == 2)

    let fiveH = usage.metrics[0]
    #expect(fiveH.label == "5h window")
    #expect(fiveH.percentUsed == 100)
    #expect(fiveH.unit == .percent)
    #expect(fiveH.windowDuration == 18000)   // 300 min → drives the pace tick
    #expect(fiveH.resetAt != nil)
    #expect(fiveH.fractionUsed == 1.0)

    let plan = usage.metrics[1]
    #expect(plan.label == "Plan window")
    #expect(plan.percentUsed == 45)
    #expect(plan.windowDuration == nil)       // no fixed length → no even-burn line
    #expect(plan.resetAt != nil)
}

/// The response says which credential it accepted. Assert it, so a silent fallback to some
/// other auth path can't pass as a healthy reading.
@Test func kimiResponseConfirmsApiKeyAuth() throws {
    let resp = try JSONDecoder().decode(KimiCollector.UsagesResponse.self, from: Data(kimiUsagesJSON.utf8))
    #expect(resp.authentication?.method == "METHOD_API_KEY")
    #expect(resp.authentication?.scope == "FEATURE_CODING")
}

@Test func kimiEmptyResponseIsError() throws {
    let usage = KimiCollector.parse(Data(#"{}"#.utf8), id: "kimi", displayName: "Kimi", plan: nil)
    #expect(usage.status == .error)
}

/// The OLD billing-RPC envelope must NOT parse as a healthy zero. If the endpoint ever
/// reverts shape, that has to surface as .error, not as a card reading 0%.
@Test func kimiLegacyEnvelopeIsError() throws {
    let legacy = #"{"usages":[{"scope":"FEATURE_CODING","detail":{"limit":"100","used":"18"}}]}"#
    let usage = KimiCollector.parse(Data(legacy.utf8), id: "kimi", displayName: "Kimi", plan: nil)
    #expect(usage.status == .error)
}

/// Live response captured 2026-09-24 at zero usage: `used` is absent and only `remaining`
/// is sent. Reading `used` alone yielded no metrics and froze the card on .error.
@Test func kimiZeroUsageWithoutUsedFieldParses() throws {
    let zero = #"{"usage":{"limit":"100","remaining":"100","resetTime":"2026-09-29T15:07:27.898421Z"},"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"100","remaining":"100","resetTime":"2026-09-24T16:07:27.898421Z"}}],"usages":{"limit_5h":{"used_ratio":0,"reset_time":"2026-09-24T16:07:27Z"},"limit_7d":{"used_ratio":0,"reset_time":"2026-09-29T15:07:27Z"}}}"#
    let usage = KimiCollector.parse(Data(zero.utf8), id: "kimi", displayName: "Kimi", plan: nil)
    #expect(usage.status == .ok)
    #expect(usage.metrics.count == 2)
    #expect(usage.metrics[0].percentUsed == 0)
    #expect(usage.metrics[1].percentUsed == 0)
}
