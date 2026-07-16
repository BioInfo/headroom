import Foundation
import Observation
import SwiftUI

/// App appearance: follow the system, or pin Light/Dark. Affects the popover and windows
/// (their cream/espresso skin). The menu-bar glyph is appearance-agnostic — its warm ramp
/// reads on both — so this never touches the menu bar.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "System"
        case .light:  "Light"
        case .dark:   "Dark"
        }
    }
    /// The forced color scheme, or nil to follow the system.
    var scheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light:  .light
        case .dark:   .dark
        }
    }
}

/// The shape of the menu-bar glyph. Orthogonal to `GlyphSource` (what it tracks): this is
/// how the fill is drawn. The chef-hat is the family mark; bar + battery are alternates for
/// people who want a flatter or more "charge-left" read.
enum GlyphStyle: String, CaseIterable, Identifiable {
    case hat        // the chef-hat gauge, fills with usage (the default family mark)
    case bar        // a slim horizontal bar, fills with usage
    case battery    // a battery that DRAINS as you spend — reads as "charge left"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hat: "Chef hat"
        case .bar: "Bar"
        case .battery: "Battery"
        }
    }
}

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
    static let allProviderIDs = ["claude", "claude-jands", "codex", "minimax", "zai", "kimi", "grok"]
    /// On by default: every provider Headroom knows about. Local-creds ones (Claude/Codex)
    /// work with zero setup; key/token ones (MiniMax/GLM/Kimi) show a one-line "add a key"
    /// prompt until pasted — the discoverable funnel, consistent across all paste providers.
    static let defaultEnabled: Set<String> = ["claude", "claude-jands", "codex", "minimax", "zai", "kimi", "grok"]

    @ObservationIgnored private let d = UserDefaults.standard

    var enabledProviders: Set<String> { didSet { d.set(Array(enabledProviders), forKey: "enabledProviders") } }
    var refreshMinutes: Int           { didSet { d.set(refreshMinutes, forKey: "refreshMinutes") } }
    /// Adaptive polling: pick the base interval from interaction recency + power/thermal
    /// state (see `AdaptiveCadence`) instead of the fixed slider. Opt-in — default off, so no
    /// existing user's fixed cadence changes without asking. When on, `refreshMinutes` is ignored.
    var adaptiveRefresh: Bool         { didSet { d.set(adaptiveRefresh, forKey: "adaptiveRefresh") } }
    var notify: Bool                  { didSet { d.set(notify, forKey: "notify") } }
    var notifySound: Bool             { didSet { d.set(notifySound, forKey: "notifySound") } }
    var notifyOnReset: Bool           { didSet { d.set(notifyOnReset, forKey: "notifyOnReset") } }
    /// Alert when a window is fully exhausted (you're locked out) and again when it's back —
    /// threshold-independent, the highest-value alert. Default on when notifications are on.
    var notifyOnDeplete: Bool         { didSet { d.set(notifyOnDeplete, forKey: "notifyOnDeplete") } }
    /// Suppress notification *delivery* until this time ("snooze"). State still advances
    /// underneath, so resuming doesn't dump a backlog — you just miss pings while muted.
    /// Persisted so a snooze survives relaunch; nil = not snoozed.
    var snoozeUntil: Date? {
        didSet {
            if let s = snoozeUntil { d.set(s.timeIntervalSince1970, forKey: "snoozeUntil") }
            else { d.removeObject(forKey: "snoozeUntil") }
        }
    }
    var notifyThresholds: [Int]       { didSet { d.set(notifyThresholds, forKey: "notifyThresholds") } }
    var showClaudeExtraUsage: Bool    { didSet { d.set(showClaudeExtraUsage, forKey: "showClaudeExtraUsage") } }
    var refreshOnWake: Bool           { didSet { d.set(refreshOnWake, forKey: "refreshOnWake") } }
    var glyphSource: GlyphSource      { didSet { d.set(glyphSource.stored, forKey: "glyphSource") } }
    var glyphStyle: GlyphStyle        { didSet { d.set(glyphStyle.rawValue, forKey: "glyphStyle") } }
    /// Force the app's Light/Dark appearance, or follow the system (default). See `AppAppearance`.
    var appearance: AppAppearance     { didSet { d.set(appearance.rawValue, forKey: "appearance") } }
    /// Per-provider pinned meter: provider id → the meter label to track in the menu bar
    /// (e.g. "claude" → "Weekly"). Absent = use that provider's tightest meter. Self-heals:
    /// if a pinned label disappears, the lookup misses and falls back to tightest.
    var pinnedMeters: [String: String] { didSet { d.set(pinnedMeters, forKey: "pinnedMeters") } }
    var checkProviderStatus: Bool     { didSet { d.set(checkProviderStatus, forKey: "checkProviderStatus") } }
    var hasOnboarded: Bool            { didSet { d.set(hasOnboarded, forKey: "hasOnboarded") } }
    /// Peak-hours indicator (Claude's busy weekday window — see `PeakHours`). Opt-in
    /// because the window is an inferred heuristic, not a published cap.
    var showPeakHours: Bool           { didSet { d.set(showPeakHours, forKey: "showPeakHours") } }
    /// When peak hours are shown, also put a flame in the menu bar (vs. only highlighting
    /// the card in the popover).
    var peakHoursFlame: Bool          { didSet { d.set(peakHoursFlame, forKey: "peakHoursFlame") } }
    /// Auto-check for app updates (Software Updates tab). Wired to a real updater once the
    /// app is Developer-ID signed + an appcast is hosted; a no-op until then.
    var autoUpdate: Bool              { didSet { d.set(autoUpdate, forKey: "autoUpdate") } }

    private init() {
        let saved = d.array(forKey: "enabledProviders") as? [String]
        enabledProviders = saved.map(Set.init) ?? Self.defaultEnabled
        refreshMinutes = (d.object(forKey: "refreshMinutes") as? Int) ?? 15
        adaptiveRefresh = d.bool(forKey: "adaptiveRefresh")   // default false (opt-in)
        notify = d.bool(forKey: "notify")                          // default false (quiet)
        notifySound = (d.object(forKey: "notifySound") as? Bool) ?? true
        notifyOnReset = (d.object(forKey: "notifyOnReset") as? Bool) ?? false
        notifyOnDeplete = (d.object(forKey: "notifyOnDeplete") as? Bool) ?? true
        snoozeUntil = (d.object(forKey: "snoozeUntil") as? Double).map { Date(timeIntervalSince1970: $0) }
        notifyThresholds = (d.array(forKey: "notifyThresholds") as? [Int]) ?? [75, 90, 95]
        showClaudeExtraUsage = d.bool(forKey: "showClaudeExtraUsage")
        refreshOnWake = (d.object(forKey: "refreshOnWake") as? Bool) ?? true
        glyphSource = GlyphSource(stored: d.string(forKey: "glyphSource") ?? "tightest")
        glyphStyle = GlyphStyle(rawValue: d.string(forKey: "glyphStyle") ?? "") ?? .hat
        appearance = AppAppearance(rawValue: d.string(forKey: "appearance") ?? "") ?? .system
        pinnedMeters = (d.dictionary(forKey: "pinnedMeters") as? [String: String]) ?? [:]
        checkProviderStatus = (d.object(forKey: "checkProviderStatus") as? Bool) ?? true
        hasOnboarded = d.bool(forKey: "hasOnboarded")   // default false → show onboarding once
        showPeakHours = d.bool(forKey: "showPeakHours")                       // default false (opt-in)
        peakHoursFlame = (d.object(forKey: "peakHoursFlame") as? Bool) ?? true
        autoUpdate = (d.object(forKey: "autoUpdate") as? Bool) ?? true

        // One-time: turn on the second Claude meter for existing installs (new installs get it
        // via defaultEnabled). Runs after all stored props are initialized; didSet doesn't fire in
        // init, so persist explicitly. Runs once, so a later manual disable sticks.
        if !d.bool(forKey: "migratedClaudeJands") {
            enabledProviders.insert("claude-jands")
            d.set(Array(enabledProviders), forKey: "enabledProviders")
            d.set(true, forKey: "migratedClaudeJands")
        }
    }

    /// The scheme a view should skin with: the pinned appearance, or the passed system
    /// scheme when following the system. Deterministic from the pref, so a forced Light/Dark
    /// wins over the ambient environment (including in the snapshot harness).
    func effectiveScheme(_ system: ColorScheme) -> ColorScheme { appearance.scheme ?? system }

    /// True while a snooze is active (its expiry is still in the future).
    var isSnoozed: Bool { (snoozeUntil.map { Date() < $0 }) ?? false }

    func isEnabled(_ id: String) -> Bool { enabledProviders.contains(id) }
    func setEnabled(_ id: String, _ on: Bool) {
        if on { enabledProviders.insert(id) } else { enabledProviders.remove(id) }
    }

    static func displayName(_ id: String) -> String {
        switch id {
        case "claude":       "Claude"
        case "claude-jands": "Claude (J&S)"
        case "codex":   "Codex"
        case "minimax": "MiniMax"
        case "zai":     "GLM (z.ai)"
        case "kimi":    "Kimi"
        case "grok":    "Grok"
        default:        id.capitalized
        }
    }

    /// How a provider authenticates — drives the Settings row UI.
    enum Kind { case local, key, web, login }
    static func kind(_ id: String) -> Kind {
        switch id {
        case "claude", "claude-jands", "codex", "grok": .local  // read local creds/logs, zero setup
        case "minimax":         .key          // paste-once API key
        case "kimi":            .key          // paste-once session token (no API key exists)
        case "zai":             .web          // pasted key (primary) OR browser login (fallback)
        default:                .key
        }
    }

    /// What the paste field accepts, for the placeholder.
    static func pastePlaceholder(_ id: String) -> String {
        id == "kimi" ? "Paste session token" : "Paste API key"
    }

    /// Provider-specific setup instructions under the paste field. Clear steps = the app
    /// works for as many people as possible, without fighting a (Google-blocked) login.
    static func setupNote(_ id: String) -> String? {
        switch id {
        case "minimax":
            return "Paste your MiniMax coding-plan key (sk-cp-…). No browser login needed."
        case "zai":
            return "Paste your GLM coding-plan key. No browser login needed. (Browser login is a fallback.)"
        case "kimi":
            return "At kimi.com (signed in), open the browser DevTools console, run  copy(localStorage.access_token)  and paste here. Works without Google login; lasts ~30 days."
        default:
            return nil
        }
    }
}
