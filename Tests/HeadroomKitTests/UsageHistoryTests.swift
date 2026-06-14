import Testing
import Foundation
@testable import HeadroomKit

@MainActor
@Suite("UsageHistory self-recorded layer")
struct UsageHistoryTests {
    private func temp() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("headroom-test-\(UUID().uuidString).json")
    }

    @Test func recordsPeakPerProviderPerDay() throws {
        let url = temp(); defer { try? FileManager.default.removeItem(at: url) }
        let h = UsageHistory(fileURL: url)
        let day = Date()
        // Two readings same day: keep the higher peak (0.6 then 0.4 → 0.6).
        h.record([ProviderUsage(provider: "claude", displayName: "Claude",
            metrics: [Metric(label: "5h", percentUsed: 60, unit: .percent)], status: .ok)], on: day)
        h.record([ProviderUsage(provider: "claude", displayName: "Claude",
            metrics: [Metric(label: "5h", percentUsed: 40, unit: .percent)], status: .ok)], on: day)
        let series = h.utilizationSeries(days: 7)
        #expect(series.count == 1)
        #expect(series.first?.fractions["claude"] == 0.6)
    }

    @Test func ignoresNonAuthoritativeAndEmpty() throws {
        let url = temp(); defer { try? FileManager.default.removeItem(at: url) }
        let h = UsageHistory(fileURL: url)
        h.record([
            ProviderUsage(provider: "x", displayName: "X",
                metrics: [Metric(label: "est", percentUsed: 90, unit: .usd, authoritative: false)], status: .ok),
            ProviderUsage(provider: "y", displayName: "Y", metrics: [], status: .needsLogin),
        ])
        // No authoritative meters → nothing recorded.
        #expect(h.utilizationSeries(days: 7).isEmpty)
    }

    @Test func persistsAcrossInstances() throws {
        let url = temp(); defer { try? FileManager.default.removeItem(at: url) }
        UsageHistory(fileURL: url).record([ProviderUsage(provider: "codex", displayName: "Codex",
            metrics: [Metric(label: "5h", percentUsed: 25, unit: .percent)], status: .ok)])
        let reloaded = UsageHistory(fileURL: url)   // fresh instance reads the file
        #expect(reloaded.utilizationSeries(days: 7).first?.fractions["codex"] == 0.25)
    }
}
