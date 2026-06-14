import Testing
import Foundation
@testable import HeadroomKit

// MARK: - Codex token-line parse (layer 2 backfill)

@Suite("Codex token backfill")
struct CodexTokenParse {
    let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    let isoPlain = ISO8601DateFormatter()

    @Test func parsesTokenCountEvent() {
        let line = #"{"timestamp":"2026-05-22T12:23:00.285Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":20235},"last_token_usage":{"input_tokens":20047,"cached_input_tokens":3456,"output_tokens":188,"total_tokens":20235}}}}"#
        let r = UsageHistory.parseCodexTokenLine(line, iso: iso, isoPlain: isoPlain)
        #expect(r?.1 == 20235)                                   // sums last_token_usage.total_tokens
        #expect(Int(r!.0.timeIntervalSince1970) == 1779452580)   // 2026-05-22T12:23:00Z
    }

    @Test func ignoresNullInfoAndOtherEvents() {
        // token_count with info:null (rate-limits-only frame) → skip
        let nullInfo = #"{"timestamp":"2026-05-22T12:22:56Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{}}}"#
        #expect(UsageHistory.parseCodexTokenLine(nullInfo, iso: iso, isoPlain: isoPlain) == nil)
        // a non-token event line → skip
        let other = #"{"timestamp":"2026-05-22T12:22:55Z","type":"response_item","payload":{"type":"message"}}"#
        #expect(UsageHistory.parseCodexTokenLine(other, iso: iso, isoPlain: isoPlain) == nil)
        // session_meta (no last_token_usage) → skip
        let meta = #"{"timestamp":"2026-05-22T12:22:55Z","type":"session_meta","payload":{"id":"x"}}"#
        #expect(UsageHistory.parseCodexTokenLine(meta, iso: iso, isoPlain: isoPlain) == nil)
    }
}

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
