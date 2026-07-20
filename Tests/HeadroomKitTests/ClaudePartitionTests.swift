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
