import Testing
import Foundation
@testable import HeadroomKit

// Real `GET /zen/go/v1/usage` response captured 2026-11-26 (API-key auth).
private let openCodeJSON = """
{"usage":{"rolling":{"status":"ok","percent":9,"resetsAt":"2026-11-26T15:17:41.000Z"},
 "weekly":{"status":"ok","percent":4,"resetsAt":"2026-11-30T00:00:00.000Z"},
 "monthly":{"status":"ok","percent":2,"resetsAt":"2026-12-20T02:01:02.000Z"}}}
"""

@Test func openCodeParsesThreeWindows() {
    let u = OpenCodeCollector.parse(Data(openCodeJSON.utf8), id: "opencode", displayName: "OpenCode Go")
    #expect(u.status == .ok)
    #expect(u.metrics.map(\.label) == ["5h window", "Weekly", "Monthly"])
    #expect(u.metrics.map(\.percentUsed) == [9, 4, 2])
    #expect(u.metrics[0].resetAt != nil)
    #expect(u.metrics[0].windowDuration == TimeInterval(18_000))
}

@Test func openCodeUnknownShapeIsErrorNotEmptyOk() {
    let u = OpenCodeCollector.parse(Data(#"{"something":"else"}"#.utf8), id: "opencode", displayName: "OpenCode Go")
    #expect(u.status == .error)
    let html = OpenCodeCollector.parse(Data("<html></html>".utf8), id: "opencode", displayName: "OpenCode Go")
    #expect(html.status == .error)
}

@Test func providerOrderAppliesSavedAndKeepsNewcomers() {
    let defaults = ["claude", "codex", "minimax", "zai", "kimi", "grok", "opencode"]
    // Saved before opencode existed; "gone" no longer exists.
    let saved = ["kimi", "zai", "claude", "gone", "codex", "minimax", "grok"]
    #expect(ProviderOrder.apply(saved: saved, to: defaults)
            == ["kimi", "zai", "claude", "codex", "minimax", "grok", "opencode"])
    #expect(ProviderOrder.apply(saved: [], to: defaults) == defaults)
    // A newly discovered Claude account lands right after its default predecessor.
    let withAcct = ["claude", "claude-acct-work", "codex", "zai"]
    #expect(ProviderOrder.apply(saved: ["zai", "codex", "claude"], to: withAcct)
            == ["zai", "codex", "claude", "claude-acct-work"])
}

@Test func providerOrderMoveSwapsAndClampsAtEnds() {
    let ids = ["a", "b", "c"]
    #expect(ProviderOrder.move("b", by: -1, in: ids) == ["b", "a", "c"])
    #expect(ProviderOrder.move("b", by: 1, in: ids) == ["a", "c", "b"])
    #expect(ProviderOrder.move("a", by: -1, in: ids) == ids)
    #expect(ProviderOrder.move("c", by: 1, in: ids) == ids)
}
