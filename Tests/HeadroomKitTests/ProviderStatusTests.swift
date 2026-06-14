import Testing
import Foundation
@testable import HeadroomKit

@Test func indicatorMapping() {
    #expect(ProviderStatus.health(fromIndicator: "none") == .operational)
    #expect(ProviderStatus.health(fromIndicator: "minor") == .degraded)
    #expect(ProviderStatus.health(fromIndicator: "major") == .down)
    #expect(ProviderStatus.health(fromIndicator: "critical") == .down)
    #expect(ProviderStatus.health(fromIndicator: "wat") == .unknown)
}

@Test func parsesStatuspageBody() {
    let ok = Data(#"{"page":{},"status":{"indicator":"none","description":"All Systems Operational"}}"#.utf8)
    #expect(ProviderStatus.parse(ok) == .operational)
    let bad = Data(#"{"status":{"indicator":"major","description":"Major Outage"}}"#.utf8)
    #expect(ProviderStatus.parse(bad) == .down)
    #expect(ProviderStatus.parse(Data("not json".utf8)) == .unknown)
    #expect(ProviderStatus.parse(Data("{}".utf8)) == .unknown)
}

@Test func statusURLOnlyForPublishers() {
    #expect(ProviderStatus.statusURL(for: "claude") != nil)
    #expect(ProviderStatus.statusURL(for: "codex") != nil)
    #expect(ProviderStatus.statusURL(for: "minimax") == nil)
    #expect(ProviderStatus.statusURL(for: "zai") == nil)
    #expect(ProviderStatus.statusURL(for: "kimi") == nil)
}

@Test func notableHealth() {
    #expect(ServiceHealth.down.isNotable)
    #expect(ServiceHealth.degraded.isNotable)
    #expect(!ServiceHealth.operational.isNotable)
    #expect(!ServiceHealth.unknown.isNotable)
}
