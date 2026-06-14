import Testing
import Foundation
@testable import HeadroomKit

// Shape captured 2026-06-14 from the in-page probe over
// kimi.gateway.billing.v1.BillingService/GetUsages (scope FEATURE_CODING) + GetSubscription.
// The probe normalizes Kimi's used/100 values and ISO reset strings to {percentUsed, resetMs}.
private let kimiProbeJSON = """
{"ok":true,"plan":"Allegretto","windows":[
  {"label":"5h window","percentUsed":39,"resetMs":1781442447898,"durationSec":18000},
  {"label":"Plan window","percentUsed":18,"resetMs":1781622447898,"durationSec":null}
]}
"""

@MainActor
@Test func kimiDecodesProbeAndBuildsMetrics() throws {
    let probe = try JSONDecoder().decode(KimiCollector.Probe.self, from: Data(kimiProbeJSON.utf8))
    #expect(probe.ok)
    #expect(probe.plan == "Allegretto")

    let metrics = KimiCollector.metrics(from: probe.windows ?? [])
    #expect(metrics.count == 2)

    let fiveH = metrics[0]
    #expect(fiveH.label == "5h window")
    #expect(fiveH.percentUsed == 39)
    #expect(fiveH.unit == .percent)
    #expect(fiveH.windowDuration == 18000)   // 300 min → drives the pace tick
    #expect(fiveH.resetAt != nil)
    #expect(fiveH.fractionUsed == 0.39)

    let plan = metrics[1]
    #expect(plan.label == "Plan window")
    #expect(plan.percentUsed == 18)
    #expect(plan.windowDuration == nil)       // no fixed length → no even-burn line
}

@MainActor
@Test func kimiNoSessionMapsToNeedsLogin() throws {
    let json = #"{"ok":false,"reason":"no-session"}"#
    let probe = try JSONDecoder().decode(KimiCollector.Probe.self, from: Data(json.utf8))
    #expect(!probe.ok)
    #expect(probe.reason == "no-session")
}
