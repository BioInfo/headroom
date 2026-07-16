import Testing
import Foundation
@testable import HeadroomKit

// The three layers that make a Claude account switch safe:
//   identity — who does this credential belong to?  (label is a claim; account.uuid is a fact)
//   refresh  — is the token alive? (a stash is a frozen copy of a ROTATING credential)
//   index    — which stash holds which account?
// Tokens here are placeholder shapes, never real.

/// Thread-safe recorder: the fetcher closures are `@Sendable`, so a captured `var` won't compile.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _hosts: [String] = []
    func note(_ h: String) { lock.lock(); _hosts.append(h); lock.unlock() }
    var hosts: [String] { lock.lock(); defer { lock.unlock() }; return _hosts }
    var count: Int { hosts.count }
}

private func resp(_ url: URL, _ code: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
}

// MARK: - identity

@Suite("Claude identity")
struct ClaudeIdentitySuite {
    let profileJSON = """
    {"account":{"uuid":"00000000-1111-2222-3333-444455556666","email":"someone@example.com",
     "full_name":"A Person","has_claude_max":true},
     "organization":{"uuid":"org-1","name":"Example Org","rate_limit_tier":"default_claude_max_20x"}}
    """

    @Test func parsesIdentityFromProfile() {
        let id = ClaudeProfile.parse(Data(profileJSON.utf8))
        #expect(id?.accountUUID == "00000000-1111-2222-3333-444455556666")
        #expect(id?.email == "someone@example.com")
        #expect(id?.organizationName == "Example Org")
        #expect(id?.rateLimitTier == "default_claude_max_20x")
    }

    @Test func rejectsProfileWithoutUUID() {
        #expect(ClaudeProfile.parse(Data(#"{"account":{"email":"x@y.z"}}"#.utf8)) == nil)
        #expect(ClaudeProfile.parse(Data("not json".utf8)) == nil)
    }

    /// A dead token and a dead network must never look alike: one means "this credential is
    /// void", the other means "we don't know". Destructive writes gate on the difference.
    @Test func distinguishesUnauthorizedFromTransport() async {
        let un = await ClaudeProfile.fetch(accessToken: "t", fetcher: { (Data(), resp($0.url!, 401)) })
        #expect(un == .failure(.unauthorized))

        struct Boom: Error {}
        let tr = await ClaudeProfile.fetch(accessToken: "t", fetcher: { _ in throw Boom() })
        guard case .failure(.transport) = tr else { Issue.record("expected .transport, got \(tr)"); return }
    }

    @Test func summaryNeverLeaksAToken() {
        #expect(ClaudeIdentity(accountUUID: "u", email: "a@b.c", organizationName: "Org").summary() == "a@b.c · Org")
        #expect(ClaudeIdentity(accountUUID: "abcdefgh-xyz").summary() == "abcdefgh…")
    }
}

// MARK: - refresh

@Suite("Claude token refresh")
struct ClaudeRefreshSuite {
    @Test func parsesRotatedPairAndExpiry() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let f = ClaudeRefresh.parse(Data(#"{"access_token":"new-at","refresh_token":"new-rt","expires_in":3600}"#.utf8), now: now)
        #expect(f?.accessToken == "new-at")
        #expect(f?.refreshToken == "new-rt")
        #expect(f?.expiresAt == now.addingTimeInterval(3600))
    }

    /// No refresh_token in the response means the server declined to rotate. That must surface
    /// as nil so `apply` KEEPS the existing one — clearing it would strand the account.
    @Test func noRotationYieldsNilRefreshToken() {
        let f = ClaudeRefresh.parse(Data(#"{"access_token":"new-at","expires_in":60}"#.utf8))
        #expect(f?.accessToken == "new-at")
        #expect(f?.refreshToken == nil)
    }

    /// invalid_grant is terminal — the family is gone. Trying the next endpoint would only turn
    /// a clear "signed out" into a confusing transport error.
    @Test func revokedIsTerminalAndDoesNotRetryLegacyEndpoint() async {
        let rec = Recorder()
        let r = await ClaudeRefresh.refresh(refreshToken: "dead", fetcher: { req in
            rec.note(req.url!.host!)
            return (Data(#"{"error":"invalid_grant"}"#.utf8), resp(req.url!, 400))
        })
        #expect(r == .failure(.revoked))
        #expect(rec.count == 1)
    }

    /// Anthropic MOVED this endpoint: console.anthropic.com now 404s. A 404 must fall through
    /// to the next URL rather than be reported as a failure.
    @Test func fallsThroughOn404ToLegacyEndpoint() async {
        let rec = Recorder()
        let r = await ClaudeRefresh.refresh(refreshToken: "rt", fetcher: { req in
            rec.note(req.url!.host!)
            if req.url!.host == "platform.claude.com" { return (Data(), resp(req.url!, 404)) }
            return (Data(#"{"access_token":"a","refresh_token":"b","expires_in":10}"#.utf8), resp(req.url!, 200))
        })
        #expect(rec.hosts == ["platform.claude.com", "console.anthropic.com"])
        guard case .success(let f) = r else { Issue.record("expected success, got \(r)"); return }
        #expect(f.accessToken == "a")
    }

    @Test func targetsCurrentEndpointFirst() {
        #expect(ClaudeRefresh.tokenURLs.first?.absoluteString == "https://platform.claude.com/v1/oauth/token")
        let req = ClaudeRefresh.request(refreshToken: "rt", url: ClaudeRefresh.tokenURLs[0])
        let body = try! JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        #expect(body["grant_type"] as? String == "refresh_token")
        #expect(body["refresh_token"] as? String == "rt")
        #expect(body["client_id"] as? String == ClaudeRefresh.clientID)
    }
}

// MARK: - apply (splice, never rebuild)

@Suite("Claude creds splice")
struct ClaudeApplySuite {
    /// The blob also carries mcpOAuth entries (paperclip, bio-research plugins) and scopes we
    /// don't own. Rebuilding it would silently sign the user out of every MCP server.
    @Test func preservesMCPTokensAndScopes() {
        let blob = """
        {"claudeAiOauth":{"accessToken":"old-at","refreshToken":"old-rt","expiresAt":111,
          "scopes":["user:inference"],"subscriptionType":"max","rateLimitTier":"t20"},
         "mcpOAuth":{"paperclip|abc":{"serverName":"paperclip","accessToken":"mcp-token"}}}
        """
        let out = ClaudeRefresh.apply(.init(accessToken: "new-at", refreshToken: "new-rt",
                                            expiresAt: Date(timeIntervalSince1970: 500)), to: blob)
        let obj = try! JSONSerialization.jsonObject(with: Data(out!.utf8)) as! [String: Any]
        let oauth = obj["claudeAiOauth"] as! [String: Any]

        #expect(oauth["accessToken"] as? String == "new-at")
        #expect(oauth["refreshToken"] as? String == "new-rt")
        #expect(oauth["expiresAt"] as? Double == 500_000)
        #expect(oauth["subscriptionType"] as? String == "max")
        #expect(oauth["scopes"] as? [String] == ["user:inference"])

        let mcp = obj["mcpOAuth"] as! [String: Any]
        let entry = mcp["paperclip|abc"] as! [String: Any]
        #expect(entry["accessToken"] as? String == "mcp-token")
    }

    @Test func keepsExistingRefreshTokenWhenServerDidNotRotate() {
        let blob = #"{"claudeAiOauth":{"accessToken":"old-at","refreshToken":"keep-me","expiresAt":1}}"#
        let out = ClaudeRefresh.apply(.init(accessToken: "new", refreshToken: nil, expiresAt: nil), to: blob)!
        let oauth = (try! JSONSerialization.jsonObject(with: Data(out.utf8)) as! [String: Any])["claudeAiOauth"] as! [String: Any]
        #expect(oauth["refreshToken"] as? String == "keep-me")
        #expect(oauth["accessToken"] as? String == "new")
    }

    @Test func rejectsNonCredsBlob() {
        #expect(ClaudeRefresh.apply(.init(accessToken: "a", refreshToken: nil, expiresAt: nil), to: #"{"nope":1}"#) == nil)
    }
}

// MARK: - index

@Suite("Claude account index")
struct ClaudeAccountIndexSuite {
    /// The exact production defect: the pointer said "business" while the live slot held the
    /// account saved as "personal". Routing a capture-away by uuid finds the right stash;
    /// routing it by the pointer clobbers the wrong one.
    @Test func routesCaptureAwayByUUIDNotByPointer() {
        var idx = ClaudeAccountIndex(activeLabel: "business")   // the pointer, lying
        idx.record(label: "personal", identity: ClaudeIdentity(accountUUID: "uuid-A", email: "a@x.com"))
        idx.record(label: "business", identity: ClaudeIdentity(accountUUID: "uuid-B", email: "b@x.com"))

        #expect(idx.label(forUUID: "uuid-A") == "personal")
        #expect(idx.label(forUUID: "uuid-A") != idx.activeLabel)
    }

    @Test func unknownUUIDResolvesToNoStash() {
        var idx = ClaudeAccountIndex()
        idx.record(label: "personal", identity: ClaudeIdentity(accountUUID: "uuid-A"))
        #expect(idx.label(forUUID: "uuid-ZZZ") == nil)
    }

    @Test func roundTripsThroughSerialization() {
        var idx = ClaudeAccountIndex(activeLabel: "work")
        idx.record(label: "work", identity: ClaudeIdentity(accountUUID: "u1", email: "w@x.com",
                                                           organizationName: "Org"),
                   at: Date(timeIntervalSince1970: 42))
        let back = ClaudeAccountIndex.deserialize(idx.serialized())
        #expect(back.activeLabel == "work")
        #expect(back.accounts["work"]?.uuid == "u1")
        #expect(back.accounts["work"]?.email == "w@x.com")
        #expect(back.accounts["work"]?.organizationName == "Org")
        #expect(back.accounts["work"]?.verifiedAt == Date(timeIntervalSince1970: 42))
    }

    @Test func forgettingTheActiveLabelClearsActive() {
        var idx = ClaudeAccountIndex(activeLabel: "personal")
        idx.record(label: "personal", identity: ClaudeIdentity(accountUUID: "u1"))
        idx.forget(label: "personal")
        #expect(idx.activeLabel == nil)
        #expect(idx.accounts.isEmpty)
    }
}
