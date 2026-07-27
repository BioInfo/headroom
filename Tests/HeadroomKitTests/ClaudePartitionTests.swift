import Foundation
import Testing
@testable import HeadroomKit

// The real ACLAuthorizationPartitionID description captured in-process from
// `Claude Code-credentials` (scratchpad/partprobe.swift). It is a hex-encoded XML plist
// carrying Partitions = ["apple-tool:", "teamid:Y5PE65HELJ"].
private let realBlob =
"3c3f786d6c2076657273696f6e3d22312e302220656e636f64696e673d225554462d38223f3e0a3c21444f43" +
"5459504520706c697374205055424c494320222d2f2f4170706c652f2f44544420504c49535420312e302f2f" +
"454e222022687474703a2f2f7777772e6170706c652e636f6d2f445444732f50726f70657274794c6973742d" +
"312e302e647464223e0a3c706c6973742076657273696f6e3d22312e30223e0a3c646963743e0a093c6b6579" +
"3e506172746974696f6e733c2f6b65793e0a093c61727261793e0a09093c737472696e673e6170706c652d74" +
"6f6f6c3a3c2f737472696e673e0a09093c737472696e673e7465616d69643a59355045363548454c4a3c2f73" +
"7472696e673e0a093c2f61727261793e0a3c2f646963743e0a3c2f706c6973743e0a"

@Test func partitionParsesRealHexPlist() {
    let parts = ClaudePartition.parsePartitions(hexDescription: realBlob)
    #expect(parts == ["apple-tool:", "teamid:Y5PE65HELJ"])
}

@Test func partitionMembershipContainment() {
    let evicted = ClaudePartition.parsePartitions(hexDescription: realBlob)   // Headroom NOT in it
    #expect(!evicted.contains("teamid:83XUJJQQL9"))   // -> collector must skip the read (no prompt)
    #expect(evicted.contains("teamid:Y5PE65HELJ"))
}

@Test func dataFromHexDecodesAndValidates() {
    #expect(ClaudePartition.dataFromHex("48656c6c6f") == Data("Hello".utf8))
    #expect(ClaudePartition.dataFromHex("xyz") == nil)   // non-hex char
    #expect(ClaudePartition.dataFromHex("abc") == nil)   // odd length
    #expect(ClaudePartition.dataFromHex("") == Data())
}

@Test func parsePartitionsRejectsGarbage() {
    #expect(ClaudePartition.parsePartitions(hexDescription: "00").isEmpty)   // not a plist
    #expect(ClaudePartition.parsePartitions(hexDescription: "zz").isEmpty)   // not hex
}

// MARK: - 1.6.6: the apple-tool: read path

// The REAL description captured from `Claude Code-credentials` on 2026-07-27, hours after a
// Claude Code token refresh. Partitions = ["apple-tool:"] and nothing else: Headroom
// (83XUJJQQL9), Claude Code (Q6L2SF6YDW) and CodexBar (Y5PE65HELJ) had ALL been pinned at
// various points and all three are gone. This is the evidence that re-pinning is a treadmill
// and that `apple-tool:` is the only durable way in.
private let evictedBlob =
"3c3f786d6c2076657273696f6e3d22312e302220656e636f64696e673d225554462d38223f3e0a3c21444f43" +
"5459504520706c697374205055424c494320222d2f2f4170706c652f2f44544420504c49535420312e302f2f" +
"454e222022687474703a2f2f7777772e6170706c652e636f6d2f445444732f50726f70657274794c6973742d" +
"312e302e647464223e0a3c706c6973742076657273696f6e3d22312e30223e0a3c646963743e0a093c6b6579" +
"3e506172746974696f6e733c2f6b65793e0a093c61727261793e0a09093c737472696e673e6170706c652d74" +
"6f6f6c3a3c2f737472696e673e0a093c2f61727261793e0a3c2f646963743e0a3c2f706c6973743e0a"

@Test func evictedRealWorldStateAdmitsOnlyTheSecurityTool() {
    let parts = ClaudePartition.parsePartitions(hexDescription: evictedBlob)
    #expect(parts == ["apple-tool:"])
    // Every team is evicted -> the in-process read must be skipped...
    #expect(!ClaudePartition.admits(partitions: parts, identifiers: ["teamid:83XUJJQQL9"]))
    #expect(!ClaudePartition.admits(partitions: parts, identifiers: ["teamid:Q6L2SF6YDW"]))
    // ...but /usr/bin/security is still admitted, so the card can stay fresh without a prompt.
    #expect(ClaudePartition.admitsSecurityTool(partitions: parts))
}

@Test func securityToolAdmittedWheneverAppleToolPresent() {
    // The pinned case: our team present alongside apple-tool: — both paths open.
    let pinned = ["apple-tool:", "teamid:83XUJJQQL9"]
    #expect(ClaudePartition.admits(partitions: pinned, identifiers: ["teamid:83XUJJQQL9"]))
    #expect(ClaudePartition.admitsSecurityTool(partitions: pinned))
    // An unrestricted item admits everyone.
    #expect(ClaudePartition.admitsSecurityTool(partitions: []))
    // `apple:` (the broader Apple partition) also covers the tool.
    #expect(ClaudePartition.admitsSecurityTool(partitions: ["apple:"]))
}

@Test func securityToolRefusedWhenAppleToolAbsent() {
    // FAIL CLOSED: a list carrying only third-party teams must not license a security spawn,
    // because that read WOULD prompt.
    let foreign = ["teamid:Y5PE65HELJ", "cdhash:deadbeef"]
    #expect(!ClaudePartition.admitsSecurityTool(partitions: foreign))
    #expect(!ClaudePartition.admits(partitions: foreign, identifiers: ["teamid:83XUJJQQL9"]))
    // ...and it is not fooled by a lookalike prefix.
    #expect(!ClaudePartition.admitsSecurityTool(partitions: ["apple-toolkit:"]))
}
