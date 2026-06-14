import Testing
import Foundation
@testable import HeadroomKit

@Test func fractionFromPercent() {
    let m = Metric(label: "tokens", percentUsed: 11, unit: .percent)
    #expect(m.fractionUsed == 0.11)
}

@Test func fractionFromUsedAndLimit() {
    let m = Metric(label: "5h", used: 250, limit: 1000, unit: .requests)
    #expect(m.fractionUsed == 0.25)
}

@Test func epochMillisRoundTrip() {
    let d = dateFromEpochMillis(1781962675996)
    #expect(d != nil)
    #expect(Int(d!.timeIntervalSince1970) == 1781962675)
}

@Test func unlimitedMeterHasNoFraction() {
    let m = Metric(label: "weekly", unit: .percent, unlimited: true)
    #expect(m.unlimited)
    #expect(m.fractionUsed == nil)       // no bar, excluded from tightest
    #expect(m.severityFraction == nil)   // never drives a tier color
    #expect(m.pace() == nil)             // no pace projection on an uncapped window
}

@Test func usageEncodes() throws {
    let u = ProviderUsage(provider: "zai", displayName: "GLM (z.ai)", plan: "pro",
                          metrics: [Metric(label: "tokens", percentUsed: 11, unit: .percent)])
    let data = try JSONEncoder().encode(u)
    #expect(data.count > 0)
}
