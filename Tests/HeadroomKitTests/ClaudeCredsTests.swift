import Testing
import Foundation
@testable import HeadroomKit

// A creds blob with an explicit epoch-ms `expiresAt`, mirroring what the Keychain slot /
// a Headroom stash holds. Tokens are placeholder shapes, never real.
private func blob(access: String = "sk-ant-oat01-abc",
                 refresh: String? = "sk-ant-ort01-xyz",
                 plan: String? = "max",
                 expiresAtMs: Int? = 2_000_000_000_000) -> String {  // 2033 — far future
    var oauth: [String: Any] = ["accessToken": access]
    if let refresh { oauth["refreshToken"] = refresh }
    if let plan { oauth["subscriptionType"] = plan }
    if let expiresAtMs { oauth["expiresAt"] = expiresAtMs }
    let data = try! JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])
    return String(data: data, encoding: .utf8)!
}

/// Build a JWT-shaped token whose payload carries `exp` (seconds). header/sig are dummies.
private func jwt(exp: Int) -> String {
    func b64url(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    return "\(b64url(#"{"alg":"none"}"#)).\(b64url(#"{"exp":\#(exp)}"#)).sig"
}

@Test func claudeCredsParsesValidBlob() {
    let c = ClaudeCreds.parse(blob())
    #expect(c != nil)
    #expect(c?.accessToken == "sk-ant-oat01-abc")
    #expect(c?.subscriptionType == "max")
    #expect(c?.hasRefresh == true)
    #expect(c?.expiresAt == Date(timeIntervalSince1970: 2_000_000_000))  // ms/1000
}

@Test func claudeCredsRejectsInvalid() {
    #expect(ClaudeCreds.parse("not json") == nil)
    #expect(ClaudeCreds.parse(#"{"something":1}"#) == nil)                 // no claudeAiOauth
    #expect(ClaudeCreds.parse(#"{"claudeAiOauth":{}}"#) == nil)            // no accessToken
    #expect(ClaudeCreds.parse(#"{"claudeAiOauth":{"accessToken":""}}"#) == nil)  // empty token
}

@Test func claudeCredsExpiresAtFromMillisAcceptsIntOrDouble() {
    // JSONSerialization may hand `expiresAt` back as Int or Double; both must work.
    #expect(ClaudeCreds.parse(blob(expiresAtMs: 1_800_000_000_000))?.expiresAt
            == Date(timeIntervalSince1970: 1_800_000_000))
    let asDouble = #"{"claudeAiOauth":{"accessToken":"a","expiresAt":1800000000000.0}}"#
    #expect(ClaudeCreds.parse(asDouble)?.expiresAt == Date(timeIntervalSince1970: 1_800_000_000))
}

@Test func claudeCredsJWTExpFallbackWhenNoExpiresAt() {
    // No `expiresAt` field → fall back to the access token's JWT `exp` claim.
    let c = ClaudeCreds.parse(blob(access: jwt(exp: 1_900_000_000), expiresAtMs: nil))
    #expect(c?.expiresAt == Date(timeIntervalSince1970: 1_900_000_000))
}

@Test func claudeCredsUnknownExpiryWhenNoFieldAndNotJWT() {
    let c = ClaudeCreds.parse(blob(access: "opaque-not-a-jwt", expiresAtMs: nil))
    #expect(c != nil)
    #expect(c?.expiresAt == nil)
    #expect(c?.isUsable() == true)   // unknown expiry is best-effort usable
}

@Test func claudeCredsUsabilityHonorsSkew() {
    let now = Date(timeIntervalSince1970: 1_000_000_000)
    // Expires 60s out, skew 120 → NOT usable (about to lapse).
    let soon = ClaudeCreds.parse(blob(expiresAtMs: Int((now.timeIntervalSince1970 + 60) * 1000)))
    #expect(soon?.isUsable(now: now, skew: 120) == false)
    // Expires 300s out → usable.
    let later = ClaudeCreds.parse(blob(expiresAtMs: Int((now.timeIntervalSince1970 + 300) * 1000)))
    #expect(later?.isUsable(now: now, skew: 120) == true)
}

@Test func claudeCredsSummaryReflectsStateAndRefresh() {
    let now = Date(timeIntervalSince1970: 1_000_000_000)
    let valid = ClaudeCreds.parse(blob(expiresAtMs: Int((now.timeIntervalSince1970 + 3600) * 1000)))!
    let s = valid.summary(now: now)
    #expect(s.contains("plan=max"))
    #expect(s.contains("valid (60m left)"))
    #expect(s.contains("refresh=yes"))

    let expired = ClaudeCreds.parse(blob(refresh: nil,
                                         expiresAtMs: Int((now.timeIntervalSince1970 - 3600) * 1000)))!
    let e = expired.summary(now: now)
    #expect(e.contains("EXPIRED (60m ago)"))
    #expect(e.contains("refresh=NO"))
}
