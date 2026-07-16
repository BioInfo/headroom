import SwiftUI
import HeadroomKit

/// Per-provider presentation: a deep-link to the provider's own usage dashboard (the
/// source of truth the popover indexes) and an on-brand monogram badge.
///
/// We deliberately do NOT ship the providers' actual logos — those are trademarks, and a
/// clean-MIT app shouldn't vendor them. A monogram disc, tinted from our own warm ramp,
/// gives each card a fast-scan mark that's unmistakably ours. Each provider gets a
/// distinct ramp tint so the two "C"s (Claude/Codex) still read apart at a glance.
enum ProviderInfo {
    /// The provider's own usage/account page. Best-effort canonical URLs; a card click
    /// opens the source of truth rather than trapping the user in the popover.
    static func dashboardURL(_ id: String) -> URL? {
        if ClaudeAccounts.isClaudeAccountID(id) { return URL(string: "https://claude.ai/settings/usage") }
        let s: String?
        switch id {
        case "codex":   s = "https://chatgpt.com/codex/settings/usage"
        case "minimax": s = "https://platform.minimax.io/user-center/basic-information"
        case "zai":     s = "https://z.ai/manage-apikey/coding-plan/personal/usage"
        case "kimi":    s = "https://www.kimi.com/code/console"
        case "grok":    s = "https://grok.com"
        default:        s = nil
        }
        return s.flatMap(URL.init(string:))
    }

    /// Monogram letter for the badge.
    static func letter(_ id: String) -> String {
        if id == "claude" { return "C" }
        // An account card takes the label's first alphanumeric so multiple Claude discs read
        // apart at a glance (e.g. "work" → "W"), falling back to "C".
        if let label = ClaudeAccounts.label(forProviderID: id) {
            return label.first { $0.isLetter || $0.isNumber }.map { String($0).uppercased() } ?? "C"
        }
        switch id {
        case "codex":   return "X"   // disambiguates from Claude's C (Code-X)
        case "minimax": return "M"
        case "zai":     return "G"   // GLM
        case "kimi":    return "K"
        case "grok":    return "R"   // gRok (G is taken by GLM, X by Codex)
        default:        return String(id.prefix(1)).uppercased()
        }
    }

    /// A distinct tier color per provider, all drawn from the cookbook ramp so the badges
    /// stay in-palette while remaining individually recognizable.
    static func tierColor(_ id: String, _ skin: Skin) -> Color {
        // All Claude accounts share the terracotta ramp; the monogram sets them apart.
        if ClaudeAccounts.isClaudeAccountID(id) { return skin.ramp(.pressing) }
        switch id {
        case "codex":   return skin.ramp(.healthy)    // olive
        case "minimax": return skin.ramp(.critical)   // rust
        case "zai":     return skin.ramp(.runaway)    // aubergine
        case "kimi":    return skin.ramp(.warming)    // clay-amber
        case "grok":    return skin.clay              // graphite-taupe (xAI reads dark; clay is our neutral)
        default:        return skin.clay
        }
    }
}

/// The little monogram disc on each provider card.
struct ProviderBadge: View {
    let id: String
    let skin: Skin
    var size: CGFloat = 18

    var body: some View {
        let tint = ProviderInfo.tierColor(id, skin)
        Circle()
            .fill(tint.opacity(0.16))
            .overlay(Circle().strokeBorder(tint.opacity(0.55), lineWidth: 1))
            .overlay(
                Text(ProviderInfo.letter(id))
                    .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
            )
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
