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
        let s: String?
        switch id {
        case "claude":       s = "https://claude.ai/settings/usage"
        case "claude-jands": s = "https://claude.ai/settings/usage"
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
        switch id {
        case "claude":       "C"
        case "claude-jands": "J"   // J&S — distinct monogram from Claude's C
        case "codex":   "X"   // disambiguates from Claude's C (Code-X)
        case "minimax": "M"
        case "zai":     "G"   // GLM
        case "kimi":    "K"
        case "grok":    "R"   // gRok (G is taken by GLM, X by Codex)
        default:        String(id.prefix(1)).uppercased()
        }
    }

    /// A distinct tier color per provider, all drawn from the cookbook ramp so the badges
    /// stay in-palette while remaining individually recognizable.
    static func tierColor(_ id: String, _ skin: Skin) -> Color {
        switch id {
        case "claude":       skin.ramp(.pressing)   // terracotta
        case "claude-jands": skin.ramp(.pressing)   // same Claude terracotta; the "J" monogram sets it apart
        case "codex":   skin.ramp(.healthy)    // olive
        case "minimax": skin.ramp(.critical)   // rust
        case "zai":     skin.ramp(.runaway)    // aubergine
        case "kimi":    skin.ramp(.warming)    // clay-amber
        case "grok":    skin.clay              // graphite-taupe (xAI reads dark; clay is our neutral)
        default:        skin.clay
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
