import Testing
import Foundation
@testable import HeadroomKit

/// A stash is a frozen copy of a credential whose access token dies in hours, so a non-live
/// account's card decays to "couldn't read usage". Refreshing the stash fixes that — but the
/// refresh is the same primitive that, aimed at the live slot, signed an account out in 1.6.1.
/// These lock the contracts that keep it safe.
@Suite("Stash refresh")
struct StashRefreshTests {

    // MARK: sticky signed-out marker (the replay guard)

    @Test func signedOutMarkerIsStickyAndSurvivesTheCodec() throws {
        var idx = ClaudeAccountIndex(accounts: ["business": .init(uuid: "u-1", email: "b@x.com")])
        #expect(!idx.isSignedOut("business"))

        let t = Date(timeIntervalSince1970: 1_700_000_000)
        idx.markSignedOut(label: "business", at: t)
        #expect(idx.isSignedOut("business"))

        // Must persist: an in-memory-only marker would replay the dead token on next launch.
        let back = ClaudeAccountIndex.deserialize(idx.serialized())
        #expect(back.isSignedOut("business"))
        #expect(back.accounts["business"]?.signedOutAt == t)
        #expect(back == idx)
    }

    @Test func reVerifyingAnAccountClearsTheSignedOutMarker() {
        var idx = ClaudeAccountIndex(accounts: ["business": .init(uuid: "u-1")])
        idx.markSignedOut(label: "business")
        #expect(idx.isSignedOut("business"))
        // A working credential is proof the stash is good again (user re-ran /login + re-saved).
        idx.record(label: "business", identity: ClaudeIdentity(accountUUID: "u-1", email: "b@x.com"))
        #expect(!idx.isSignedOut("business"))
    }

    @Test func markSignedOutCreatesAStubForAnUnindexedStash() {
        // A stash captured by the old shell tool has no index entry, but the sticky marker
        // MUST still take — otherwise the dead token replays every tick. It stubs uuid.
        var idx = ClaudeAccountIndex()
        idx.markSignedOut(label: "business")
        #expect(idx.isSignedOut("business"))
        #expect(idx.accounts["business"]?.uuid == "unknown")
        // Survives the codec, and a later verified re-capture clears it.
        #expect(ClaudeAccountIndex.deserialize(idx.serialized()).isSignedOut("business"))
        idx.record(label: "business", identity: ClaudeIdentity(accountUUID: "u-real", email: "b@x.com"))
        #expect(!idx.isSignedOut("business"))
        #expect(idx.accounts["business"]?.uuid == "u-real")
    }

    // MARK: transient-failure backoff (the anti-429 guard)

    @Test func backoffBlocksRetryUntilItExpiresAndSurvivesTheCodec() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var idx = ClaudeAccountIndex()
        #expect(idx.canRefresh("business", now: now))                 // unknown label → allowed
        idx.backOffRefresh(label: "business", until: now.addingTimeInterval(1800))
        #expect(!idx.canRefresh("business", now: now))                // inside window → blocked
        #expect(!idx.canRefresh("business", now: now.addingTimeInterval(1799)))
        #expect(idx.canRefresh("business", now: now.addingTimeInterval(1801)))   // past window → allowed
        // persists
        let back = ClaudeAccountIndex.deserialize(idx.serialized())
        #expect(!back.canRefresh("business", now: now))
    }

    @Test func aSuccessfulReVerifyAndBackoffClearBothInteract() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var idx = ClaudeAccountIndex()
        idx.backOffRefresh(label: "business", until: now.addingTimeInterval(1800))
        idx.clearRefreshBackoff(label: "business")
        #expect(idx.canRefresh("business", now: now))
    }

    @Test func signedOutOutranksBackoff() {
        // A revoked stash must stay blocked regardless of any backoff window.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var idx = ClaudeAccountIndex()
        idx.markSignedOut(label: "business", at: now)
        idx.backOffRefresh(label: "business", until: now.addingTimeInterval(-1))   // window "expired"
        #expect(!idx.canRefresh("business", now: now))   // still blocked: signed out is terminal
    }

    // MARK: the live slot must be unreachable from this path

    @Test func refreshRefusesTheLiveSlot() async {
        // The stash service is always prefixed; an empty label is the only way this could
        // ever collapse toward the live item. Refuse it outright.
        let r = await ClaudeAccounts.refreshStashIfNeeded("")
        #expect(r == .failed("refusing to refresh the live slot"))
    }

    @Test func stashServiceNamesCanNeverCollideWithTheLiveSlot() {
        // Belt-and-braces on the guard above: no label can produce the live service name.
        for label in ["", "personal", "business", "Claude Code-credentials", "../../x"] {
            #expect(ClaudeAccounts.stashPrefix + label != ClaudeAccounts.liveService)
        }
    }

    // MARK: refresh semantics (pure pieces — no network, no keychain)

    @Test func applyPreservesUnrelatedFieldsIncludingMcpOAuth() throws {
        // A rebuild would silently drop mcpOAuth.* and sign the user out of every MCP server.
        let blob = #"""
        {"claudeAiOauth":{"accessToken":"old","refreshToken":"r-old","expiresAt":1000,
        "scopes":["user:inference"],"subscriptionType":"max"},
        "mcpOAuth":{"paperclip":{"token":"keep-me"}}}
        """#
        let fresh = ClaudeRefresh.Fresh(accessToken: "new", refreshToken: "r-new",
                                        expiresAt: Date(timeIntervalSince1970: 5000))
        let out = try #require(ClaudeRefresh.apply(fresh, to: blob))
        let o = try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        let oauth = try #require(o["claudeAiOauth"] as? [String: Any])
        #expect(oauth["accessToken"] as? String == "new")
        #expect(oauth["refreshToken"] as? String == "r-new")
        #expect(oauth["subscriptionType"] as? String == "max")        // untouched
        #expect(oauth["scopes"] as? [String] == ["user:inference"])   // untouched
        #expect(((o["mcpOAuth"] as? [String: Any])?["paperclip"] as? [String: Any])?["token"] as? String == "keep-me")
    }

    @Test func applyKeepsTheExistingRefreshTokenWhenTheServerDidNotRotate() throws {
        let blob = #"{"claudeAiOauth":{"accessToken":"old","refreshToken":"r-old","expiresAt":1000}}"#
        let fresh = ClaudeRefresh.Fresh(accessToken: "new", refreshToken: nil, expiresAt: nil)
        let out = try #require(ClaudeRefresh.apply(fresh, to: blob))
        let oauth = try #require((try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])?["claudeAiOauth"] as? [String: Any])
        #expect(oauth["accessToken"] as? String == "new")
        #expect(oauth["refreshToken"] as? String == "r-old")   // nil must NOT clear it
    }

    @Test func invalidGrantIsTerminalAndNotRetriedAcrossEndpoints() async {
        // 400 => the token family is dead. Trying the legacy endpoint too would be a second
        // replay of the same dead token; it must stop at the first invalid_grant.
        let calls = Counter()
        let r = await ClaudeRefresh.refresh(refreshToken: "dead", fetcher: { req in
            await calls.bump()
            return (Data(#"{"error":"invalid_grant"}"#.utf8),
                    HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!)
        })
        #expect(r == .failure(.revoked))
        #expect(await calls.value == 1)
    }

    @Test func a404FallsThroughToTheLegacyEndpoint() async {
        let seen = Hosts()
        let r = await ClaudeRefresh.refresh(refreshToken: "r", fetcher: { req in
            await seen.add(req.url!.host!)
            if req.url!.host == "platform.claude.com" {
                return (Data(), HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            }
            return (Data(#"{"access_token":"a","refresh_token":"b","expires_in":3600}"#.utf8),
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        #expect(await seen.value == ["platform.claude.com", "console.anthropic.com"])
        if case .success(let f) = r { #expect(f.accessToken == "a") } else { Issue.record("expected success") }
    }

    /// Actors: the fetcher is @Sendable and runs concurrently, so test spies need isolation.
    actor Counter { var value = 0; func bump() { value += 1 } }
    actor Hosts { var value: [String] = []; func add(_ h: String) { value.append(h) } }
}
