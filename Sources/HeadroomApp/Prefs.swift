import Foundation
import Observation

/// What the menu-bar % + hat fill should track.
enum GlyphSource: Equatable {
    case tightest               // the hottest authoritative meter across enabled providers
    case providers([String])    // up to 3 specific providers, side by side
    case hatOnly                // just the hat, no number

    /// Cap on how many providers the multi-metric bar shows side by side.
    static let maxProviders = 3

    var stored: String {
        switch self {
        case .tightest:          "tightest"
        case .hatOnly:           "hatOnly"
        case .providers(let ps): "providers:" + ps.joined(separator: ",")
        }
    }
    init(stored: String) {
        if stored == "hatOnly" { self = .hatOnly }
        else if stored.hasPrefix("providers:") {
            let ids = String(stored.dropFirst("providers:".count))
                .split(separator: ",").map(String.init).filter { !$0.isEmpty }
            self = ids.isEmpty ? .tightest : .providers(Array(ids.prefix(Self.maxProviders)))
        }
        // legacy single-provider value migrates to the list form
        else if stored.hasPrefix("provider:") {
            let id = String(stored.dropFirst("provider:".count))
            self = id.isEmpty ? .tightest : .providers([id])
        }
        else { self = .tightest }
    }
}

/// User settings, persisted in `UserDefaults`. Observable so views + `AppModel` react.
/// Stored vars persist on write (didSet); reads come from the in-memory value seeded
/// from defaults at launch.
@MainActor
@Observable
final class Prefs {
    static let shared = Prefs()

    /// Every provider Headroom knows about, in display order.
    static let allProviderIDs = ["claude", "codex", "minimax", "zai", "kimi"]
    /// On by default: the providers that work with zero setup (local creds) or a key the
    /// user likely already has. Kimi is webview-login-only, so it stays off until the user
    /// logs in once — the popover starts clean.
    static let defaultEnabled: Set<String> = ["claude", "codex", "minimax", "zai"]

    @ObservationIgnored private let d = UserDefaults.standard

    var enabledProviders: Set<String> { didSet { d.set(Array(enabledProviders), forKey: "enabledProviders") } }
    var refreshMinutes: Int           { didSet { d.set(refreshMinutes, forKey: "refreshMinutes") } }
    var notify: Bool                  { didSet { d.set(notify, forKey: "notify") } }
    var notifyThresholds: [Int]       { didSet { d.set(notifyThresholds, forKey: "notifyThresholds") } }
    var showClaudeExtraUsage: Bool    { didSet { d.set(showClaudeExtraUsage, forKey: "showClaudeExtraUsage") } }
    var refreshOnWake: Bool           { didSet { d.set(refreshOnWake, forKey: "refreshOnWake") } }
    var glyphSource: GlyphSource      { didSet { d.set(glyphSource.stored, forKey: "glyphSource") } }

    private init() {
        let saved = d.array(forKey: "enabledProviders") as? [String]
        enabledProviders = saved.map(Set.init) ?? Self.defaultEnabled
        refreshMinutes = (d.object(forKey: "refreshMinutes") as? Int) ?? 15
        notify = d.bool(forKey: "notify")                          // default false (quiet)
        notifyThresholds = (d.array(forKey: "notifyThresholds") as? [Int]) ?? [75, 90, 95]
        showClaudeExtraUsage = d.bool(forKey: "showClaudeExtraUsage")
        refreshOnWake = (d.object(forKey: "refreshOnWake") as? Bool) ?? true
        glyphSource = GlyphSource(stored: d.string(forKey: "glyphSource") ?? "tightest")
    }

    func isEnabled(_ id: String) -> Bool { enabledProviders.contains(id) }
    func setEnabled(_ id: String, _ on: Bool) {
        if on { enabledProviders.insert(id) } else { enabledProviders.remove(id) }
    }

    static func displayName(_ id: String) -> String {
        switch id {
        case "claude":  "Claude"
        case "codex":   "Codex"
        case "minimax": "MiniMax"
        case "zai":     "GLM (z.ai)"
        case "kimi":    "Kimi"
        default:        id.capitalized
        }
    }

    /// How a provider authenticates — drives the Settings row UI.
    enum Kind { case local, key, web, login }
    static func kind(_ id: String) -> Kind {
        switch id {
        case "claude", "codex": .local        // read local creds/logs
        case "minimax":         .key          // paste-once API key
        case "zai":             .web          // webview login OR a pasted key
        case "kimi":            .login        // webview login only (no key path)
        default:                .login
        }
    }
}
