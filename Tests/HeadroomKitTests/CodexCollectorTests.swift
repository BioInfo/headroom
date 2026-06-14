import Testing
import Foundation
@testable import HeadroomKit

// Real response captured 2026-06-13 from chatgpt.com/backend-api/wham/usage
// (see docs/PROVIDERS.md). primary_window ≈ 5h, secondary_window ≈ weekly.
private let whamUsageJSON = #"""
{"user_id":"user-x","email":"x@example.com","plan_type":"plus","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":2,"limit_window_seconds":18000,"reset_after_seconds":17813,"reset_at":1781417829},"secondary_window":{"used_percent":0,"limit_window_seconds":604800,"reset_after_seconds":604613,"reset_at":1782004629}},"rate_limit_reset_credits":{"available_count":1}}
"""#

@Test func codexParsesLiveWindows() throws {
    let resp = try JSONDecoder().decode(CodexCollector.Response.self,
                                        from: Data(whamUsageJSON.utf8))
    #expect(resp.plan_type == "plus")
    let m = resp.metrics
    #expect(m.map(\.label) == ["5h window", "Weekly"])

    let five = m.first { $0.label == "5h window" }
    let week = m.first { $0.label == "Weekly" }
    #expect(five?.percentUsed == 2)
    #expect(week?.percentUsed == 0)
    #expect(five?.unit == .percent)
    // reset_at is epoch SECONDS (matches the app's reset, not 2 days stale).
    #expect(five?.resetAt.map { Int($0.timeIntervalSince1970) } == 1781417829)
    #expect(week?.resetAt.map { Int($0.timeIntervalSince1970) } == 1782004629)
}

@Test func codexNoRateLimitYieldsNoMetrics() throws {
    let json = #"{"plan_type":"plus","rate_limit":null}"#
    let resp = try JSONDecoder().decode(CodexCollector.Response.self, from: Data(json.utf8))
    #expect(resp.metrics.isEmpty)
}

@Test func codexAuthReadsAccessToken() throws {
    // readAuth pulls tokens.access_token + account_id from an auth.json blob.
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-auth-\(UUID().uuidString).json")
    let blob = #"{"auth_mode":"chatgpt","tokens":{"access_token":"eyJtest","account_id":"acc-1"}}"#
    try blob.write(to: tmp, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let auth = CodexCollector.readAuth(tmp)
    #expect(auth?.accessToken == "eyJtest")
    #expect(auth?.accountId == "acc-1")
}
