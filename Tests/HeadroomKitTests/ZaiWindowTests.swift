import Testing
import Foundation
@testable import HeadroomKit

@Suite struct ZaiWindowTests {
    typealias L = ZaiCollector.Limit

    @Test func knownUnitsSeconds() {
        #expect(L.windowSeconds(5, 3) == 18_000)
        #expect(L.windowSeconds(30, 2) == 1_800)
        #expect(L.windowSeconds(2, 4) == 172_800)
        #expect(L.windowSeconds(1, 5) == 2_629_800)
    }

    @Test func weekUnitSixIsSevenDays() {
        #expect(L.windowSeconds(1, 6) == 604_800)
        #expect(L.windowSeconds(2, 6) == 1_209_600)
        #expect(L.windowLabel(1, 6) == "Weekly")
        #expect(L.windowLabel(2, 6) == "2w window")
    }

    @Test func labels() {
        #expect(L.windowLabel(5, 3) == "5h window")
        #expect(L.windowLabel(1, 5) == "Monthly")
        #expect(L.windowLabel(nil, nil) == "Usage")
    }

    @Test func unknownUnitIsVisibleAndHasNoDuration() {
        #expect(L.windowSeconds(1, 9) == nil)
        #expect(L.windowLabel(1, 9) == "Usage (unit 9)")
    }
}
