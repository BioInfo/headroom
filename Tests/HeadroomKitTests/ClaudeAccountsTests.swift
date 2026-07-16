import Testing
@testable import HeadroomKit

// The Keychain/file operations touch the real login Keychain and aren't unit-testable here;
// these cover the pure id<->label + label-sanitization helpers that the rest of the app
// keys off (provider-id routing, display, capture-name normalization).

@Test func claudeAccountIDRecognition() {
    #expect(ClaudeAccounts.isClaudeAccountID("claude"))
    #expect(ClaudeAccounts.isClaudeAccountID("claude-acct-work"))
    #expect(!ClaudeAccounts.isClaudeAccountID("codex"))
    #expect(!ClaudeAccounts.isClaudeAccountID("claude-ish"))   // not the acct prefix
}

@Test func claudeAccountLabelRoundTrips() {
    #expect(ClaudeAccounts.label(forProviderID: "claude-acct-work") == "work")
    #expect(ClaudeAccounts.label(forProviderID: "claude") == nil)          // base has no label
    #expect(ClaudeAccounts.label(forProviderID: "codex") == nil)
    #expect(ClaudeAccounts.providerID(forLabel: "work") == "claude-acct-work")
    #expect(ClaudeAccounts.label(forProviderID: ClaudeAccounts.providerID(forLabel: "j-s")) == "j-s")
}

@Test func claudeAccountSanitizeLabel() {
    #expect(ClaudeAccounts.sanitizeLabel("Personal") == "personal")
    #expect(ClaudeAccounts.sanitizeLabel("Work Laptop") == "work-laptop")
    #expect(ClaudeAccounts.sanitizeLabel("  J&S!!  ") == "js")               // strip non-alnum, trim
    #expect(ClaudeAccounts.sanitizeLabel("a--b") == "a-b")                    // collapse dashes
    #expect(ClaudeAccounts.sanitizeLabel("-lead-trail-") == "lead-trail")     // trim edge dashes
    #expect(ClaudeAccounts.sanitizeLabel("###") == nil)                       // nothing usable
    #expect(ClaudeAccounts.sanitizeLabel("") == nil)
}
