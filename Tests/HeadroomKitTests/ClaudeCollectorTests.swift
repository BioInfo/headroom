import Testing
import Foundation
@testable import HeadroomKit

// Real response shape captured 2026-06-13 from api.anthropic.com/api/oauth/usage
// (see docs/PROVIDERS.md). Null sibling windows must be ignored; extra_usage maps
// only when enabled.
private let claudeUsageJSON = #"""
{"five_hour":{"utilization":30.0,"resets_at":"2026-06-14T02:59:59.160907+00:00"},"seven_day":{"utilization":15.0,"resets_at":"2026-06-17T20:59:59.160933+00:00"},"seven_day_oauth_apps":null,"seven_day_opus":null,"seven_day_sonnet":{"utilization":3.0,"resets_at":"2026-06-17T21:00:00.160945+00:00"},"tangelo":null,"extra_usage":{"is_enabled":true,"monthly_limit":5000,"used_credits":3462.0,"utilization":69.24,"currency":"USD","disabled_reason":null}}
"""#

@Test func claudeDecodesWindowsSkippingNulls() throws {
    let usage = try JSONDecoder().decode(ClaudeCollector.Usage.self,
                                         from: Data(claudeUsageJSON.utf8))
    let m = usage.metrics
    // five_hour, seven_day, seven_day_sonnet — opus is null (dropped); extra_usage is
    // intentionally not surfaced (a $ pool, not headroom).
    #expect(m.count == 3)
    #expect(m.map(\.label) == ["5h window", "Weekly", "Weekly (Sonnet)"])

    let five = m.first { $0.label == "5h window" }
    #expect(five?.percentUsed == 30.0)
    #expect(five?.unit == .percent)
    #expect(five?.fractionUsed == 0.30)
    // microsecond + offset timestamp must parse via the fractional formatter.
    #expect(five?.resetAt != nil)
}

@Test func claudeExtraUsageNotInWindowMetrics() throws {
    // The window metrics never include Extra usage — it's a $ pool, kept out of the
    // default set so it can't hijack the menu-bar glyph.
    let usage = try JSONDecoder().decode(ClaudeCollector.Usage.self,
                                         from: Data(claudeUsageJSON.utf8))
    #expect(usage.metrics.first { $0.label == "Extra usage" } == nil)
}

@Test func claudeExtraUsageMetricOptIn() throws {
    // Opt-in path: extraUsageMetric carries credits + percent when enabled.
    let usage = try JSONDecoder().decode(ClaudeCollector.Usage.self,
                                         from: Data(claudeUsageJSON.utf8))
    let extra = usage.extraUsageMetric
    #expect(extra?.percentUsed == 69.24)
    #expect(extra?.used == 3462.0)
    #expect(extra?.limit == 5000)
    #expect(extra?.unit == .usd)
}

@Test func claudeExtraUsageHiddenWhenDisabled() throws {
    let json = #"{"five_hour":{"utilization":10.0,"resets_at":"2026-06-14T03:00:00.0+00:00"},"extra_usage":{"is_enabled":false,"monthly_limit":5000,"used_credits":0.0,"utilization":0.0}}"#
    let usage = try JSONDecoder().decode(ClaudeCollector.Usage.self, from: Data(json.utf8))
    #expect(usage.metrics.map(\.label) == ["5h window"])
}

@Test func claudeParsesISOWithMicrosecondsAndOffset() {
    let d = ClaudeCollector.parseISO("2026-06-14T02:59:59.160907+00:00")
    #expect(d != nil)
    #expect(ClaudeCollector.parseISO(nil) == nil)
}

// MARK: - credential freshness (the logout/login stale-file-vs-live-Keychain bug)

/// `expiresAt` is epoch ms; both stores carry it so an expired token can't shadow a live one.
@Test func claudeCredsParseExpiresAtFromMillis() {
    let json = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-x","subscriptionType":"max","expiresAt":1782679712840}}"#
    let c = ClaudeCollector.creds(fromJSON: Data(json.utf8))
    #expect(c?.accessToken == "sk-ant-oat01-x")
    #expect(c?.subscriptionType == "max")
    #expect(c?.expiresAt == Date(timeIntervalSince1970: 1782679712.840))
}

@Test func claudeCredsUsabilityHonorsExpiry() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let live = ClaudeCollector.Creds(accessToken: "t", subscriptionType: "max",
                                     expiresAt: now.addingTimeInterval(3600))
    let dead = ClaudeCollector.Creds(accessToken: "t", subscriptionType: "max",
                                     expiresAt: now.addingTimeInterval(-3600))
    let empty = ClaudeCollector.Creds(accessToken: "", subscriptionType: "max",
                                      expiresAt: now.addingTimeInterval(3600))
    let unknown = ClaudeCollector.Creds(accessToken: "t", subscriptionType: "max", expiresAt: nil)
    #expect(live.isUsable(now: now))
    #expect(!dead.isUsable(now: now))                 // expired → not usable
    #expect(!empty.isUsable(now: now))                // no token → not usable
    #expect(unknown.isUsable(now: now))               // unknown expiry → best-effort usable
    // skew: a token lapsing within 120s is treated as already gone.
    let soon = ClaudeCollector.Creds(accessToken: "t", subscriptionType: "max",
                                     expiresAt: now.addingTimeInterval(60))
    #expect(!soon.isUsable(now: now))
}

/// The exact incident: file token expired, Keychain token still valid → Keychain wins.
@Test func claudeFresherPrefersLaterExpiringToken() {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let staleFile = ClaudeCollector.Creds(accessToken: "old", subscriptionType: "max",
                                          expiresAt: t0.addingTimeInterval(-86400))
    let liveKeychain = ClaudeCollector.Creds(accessToken: "new", subscriptionType: "max",
                                             expiresAt: t0.addingTimeInterval(3600))
    #expect(ClaudeCollector.fresher(staleFile, liveKeychain)?.accessToken == "new")
    #expect(ClaudeCollector.fresher(liveKeychain, staleFile)?.accessToken == "new")
    // one side missing → take the present one; both missing → nil.
    #expect(ClaudeCollector.fresher(staleFile, nil)?.accessToken == "old")
    #expect(ClaudeCollector.fresher(nil, liveKeychain)?.accessToken == "new")
    #expect(ClaudeCollector.fresher(nil, nil) == nil)
}

/// readCreds end to end: a valid file token is the fast path; an expired one is not
/// returned as usable, so it can never shadow a live Keychain token.
@Test func claudeReadCredsSkipsExpiredFile() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("hr-claude-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent(".credentials.json")
    let noKeychain = "Headroom-no-such-service-\(UUID().uuidString)"

    // A valid (far-future) file token IS used as the fast path.
    let liveJSON = #"{"claudeAiOauth":{"accessToken":"file-live","subscriptionType":"max","expiresAt":4102444800000}}"#
    try Data(liveJSON.utf8).write(to: path)
    #expect(ClaudeCollector(credentialsPath: path, keychainService: noKeychain)
              .readCreds()?.accessToken == "file-live")

    // An expired file token is NOT usable → fast path skipped (it never shadows a live token).
    let deadJSON = #"{"claudeAiOauth":{"accessToken":"file-dead","subscriptionType":"max","expiresAt":1000000000000}}"#
    try Data(deadJSON.utf8).write(to: path)
    #expect(ClaudeCollector.credsFromFile(path)?.isUsable() == false)
}
