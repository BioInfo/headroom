import Testing
import Foundation
@testable import HeadroomKit

@Test func cadenceIntervals() {
    let base: TimeInterval = 15 * 60
    #expect(RefreshCadence.standard.interval(base: base) == base)
    #expect(RefreshCadence.relaxed.interval(base: base) == base * 2)
}

@Test func localCollectorsAreStandardRemoteAreRelaxed() {
    #expect(ClaudeCollector().cadence == .standard)
    #expect(CodexCollector().cadence == .standard)
    #expect(MiniMaxCollector().cadence == .relaxed)
    #expect(KimiCollector().cadence == .relaxed)
}
