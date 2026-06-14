import Testing
import Foundation
@testable import HeadroomKit

private func day(_ offset: Int) -> Date {
    Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        .addingTimeInterval(Double(offset) * 86400)
}

@Test func csvHasHeaderAndLongRows() {
    let util = [DayUtilization(day: day(0), fractions: ["claude": 0.5, "codex": 0.25])]
    let tokens = [TokenDay(day: day(0), tokens: 1234)]
    let csv = HistoryExport.csv(utilization: util, tokens: tokens)
    let lines = csv.split(separator: "\n").map(String.init)
    #expect(lines.first == "date,provider,metric,value")
    #expect(lines.contains { $0.hasSuffix(",claude,utilization,0.5000") })
    #expect(lines.contains { $0.hasSuffix(",codex,utilization,0.2500") })
    #expect(lines.contains { $0.hasSuffix(",claude,tokens,1234") })
}

@Test func jsonRoundTripsStructure() throws {
    let util = [DayUtilization(day: day(0), fractions: ["claude": 0.5])]
    let tokens = [TokenDay(day: day(0), tokens: 99)]
    let json = HistoryExport.json(utilization: util, tokens: tokens)
    let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    #expect(obj?["exported"] != nil)
    let u = obj?["utilization"] as? [[String: Any]]
    #expect((u?.first?["fractions"] as? [String: Any])?["claude"] as? Double == 0.5)
    let t = obj?["tokens"] as? [[String: Any]]
    #expect(t?.first?["tokens"] as? Int == 99)
}

@Test func exportEmptyIsValid() {
    #expect(HistoryExport.csv(utilization: [], tokens: []) == "date,provider,metric,value\n")
    #expect(HistoryExport.json(utilization: [], tokens: []).contains("\"tokens\""))
}
