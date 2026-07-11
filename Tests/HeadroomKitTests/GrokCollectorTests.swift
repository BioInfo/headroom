import Testing
import Foundation
@testable import HeadroomKit

// Real response shape captured 2026-07-11 from
// GET https://cli-chat-proxy.grok.com/v1/billing?format=credits (Bearer + x-grok-client-version).
// creditUsagePercent is the weekly usage %; currentPeriod is the billing window.
private let grokBillingJSON = #"""
{"config":{"billingPeriodEnd":"2026-07-12T13:44:34.109152+00:00","billingPeriodStart":"2026-07-05T13:44:34.109152+00:00","creditUsagePercent":100.0,"currentPeriod":{"end":"2026-07-12T13:44:34.109152+00:00","start":"2026-07-05T13:44:34.109152+00:00","type":"USAGE_PERIOD_TYPE_WEEKLY"},"isUnifiedBillingUser":true,"onDemandCap":{"val":0},"onDemandUsed":{"val":0},"prepaidBalance":{"val":0},"productUsage":[{"product":"Api","usagePercent":96.0},{"product":"GrokChat","usagePercent":4.0}],"subscriptionTier":"SuperGrok"}}
"""#

@Test func grokDecodesWeeklyCreditMeter() throws {
    let resp = try JSONDecoder().decode(GrokCollector.Response.self,
                                        from: Data(grokBillingJSON.utf8))
    let m = resp.config?.metrics ?? []
    #expect(m.count == 1)
    let weekly = m.first
    #expect(weekly?.label == "Weekly")
    #expect(weekly?.percentUsed == 100)
    #expect(weekly?.fractionUsed == 1.0)          // capped → full bar
    #expect(weekly?.unit == .percent)
    // microsecond + offset timestamp parses via the fractional formatter.
    #expect(weekly?.resetAt != nil)
    // window length from start→end is ~7 days.
    #expect(weekly?.windowDuration == 604_800)
}

@Test func grokUsesSubscriptionTierAsPlan() throws {
    let resp = try JSONDecoder().decode(GrokCollector.Response.self,
                                        from: Data(grokBillingJSON.utf8))
    #expect(resp.config?.subscriptionTier == "SuperGrok")
}

@Test func grokPeriodTypeDrivesLabel() {
    #expect(GrokCollector.Period(start: nil, end: nil, type: "USAGE_PERIOD_TYPE_WEEKLY").label == "Weekly")
    #expect(GrokCollector.Period(start: nil, end: nil, type: "USAGE_PERIOD_TYPE_MONTHLY").label == "Monthly")
    #expect(GrokCollector.Period(start: nil, end: nil, type: nil).label == "Usage period")
}

@Test func grokTokenReadFromAuthJSONStructurally() {
    // auth.json keys the entry by the OIDC issuer::client_id; we match the first entry
    // carrying a non-empty `key`, without hard-coding the client_id.
    let json = #"""
    {"https://auth.x.ai::00000000-0000-0000-0000-000000000000":{"key":"grok-oat-fixture","refresh_token":"r","expires_at":"2026-07-11T13:48:47Z","email":"x@y.com"}}
    """#
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("grok-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let p = dir.appendingPathComponent("auth.json")
    try? Data(json.utf8).write(to: p)
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(GrokCollector.readToken(p) == "grok-oat-fixture")
    #expect(GrokCollector.readToken(dir.appendingPathComponent("missing.json")) == nil)
}

@Test func grokEmptyOrMissingCreditsYieldsNoMeter() throws {
    // A response with no creditUsagePercent produces no meter (rather than a 0% phantom).
    let json = #"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY"}}}"#
    let resp = try JSONDecoder().decode(GrokCollector.Response.self, from: Data(json.utf8))
    #expect(resp.config?.metrics.isEmpty == true)
}

@Test func grokParsesPlainISOFallback() {
    // Offset without fractional seconds still parses (the fallback formatter).
    #expect(GrokCollector.parseISO("2026-07-12T13:44:34+00:00") != nil)
    #expect(GrokCollector.parseISO("2026-07-12T13:44:34.109152+00:00") != nil)
    #expect(GrokCollector.parseISO(nil) == nil)
}
