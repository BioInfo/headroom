import Foundation
import Observation
import WebKit
import AppKit
import HeadroomKit

@MainActor
@Observable
final class AppModel {
    var usages: [ProviderUsage] = []
    var isRefreshing = false
    var lastRefresh: Date?

    /// The menu-bar glyph state, held as STORED observable properties and recomputed
    /// explicitly (`recomputeMenuBar`) whenever usages or the glyph prefs change. The
    /// `MenuBarExtra` label reads these directly so it has an unambiguous Observation
    /// dependency — relying on the label tracking a computed property that reaches into a
    /// second @Observable (`prefs`) was unreliable, so a settings change didn't reflect
    /// until the next refresh tick or a restart. These do.
    var menuBarItems: [GlyphItem] = []
    var menuBarShowsPercent = true
    var menuBarStyle: GlyphStyle = .hat
    /// Whether to draw the peak-hours flame in the menu bar right now (opt-in + flame
    /// sub-toggle + currently inside Claude's busy window). Recomputed with the glyph state.
    var menuBarFlame = false

    /// The fully-composited menu-bar label as ONE image (flame + every provider's hat + its
    /// %), recomputed in `recomputeMenuBar`. The `MenuBarExtra` label is just `Image(nsImage:)`
    /// of this — a single-image swap is the only label shape a MenuBarExtra renders reliably.
    /// A multi-subview `ForEach` label updated the first hat but silently dropped a 2nd
    /// provider's hat (structural growth not reflected); compositing sidesteps that entirely.
    var menuBarImage: NSImage = NSImage()
    var menuBarA11y: String = "Headroom usage"

    /// Peak hours are active and the user opted in — drives the popover's Claude card
    /// highlight. Computed live so it's current each time the popover opens.
    var peakHoursActive: Bool { prefs.showPeakHours && PeakHours.isPeak() }

    /// Warm cache of each provider's token-history series (Claude, Codex) so the History
    /// window opens instantly instead of blocking on a local-log parse ("Reading local
    /// logs…"). Precomputed off the main thread on launch and refreshed each cycle; the
    /// window reads this and quietly updates in place. Keyed by provider id; empty for a
    /// provider only until its first warm completes (or if it has no local token logs).
    var historyTokensByProvider: [String: [TokenDay]] = [:]
    @ObservationIgnored private var historyWarming = false

    /// Kick a background parse of every token provider's local logs into the warm cache.
    /// Cheap to call often (each parse only reads log files modified in the window); coalesced
    /// so overlapping refreshes don't stack parses. Providers warm concurrently.
    func warmHistory(days: Int = 182) {
        guard !historyWarming else { return }
        historyWarming = true
        Task { [weak self] in
            var next: [String: [TokenDay]] = [:]
            await withTaskGroup(of: (String, [TokenDay]).self) { group in
                for p in UsageHistory.tokenProviders {
                    group.addTask { (p, await UsageHistory.tokenSeries(for: p, days: days)) }
                }
                for await (p, series) in group { next[p] = series }
            }
            await MainActor.run {
                self?.historyTokensByProvider = next
                self?.historyWarming = false
            }
        }
    }

    /// Which provider the login window should authenticate. Set when a card's
    /// "Log in" button is tapped, read by the login window to pick the webview.
    var loginTargetID: String?

    let prefs = Prefs.shared
    /// App self-update (stub until Developer-ID signing + an appcast exist; see Updater).
    let updater = Updater()

    // z.ai keeps a persistent WKWebView for its (optional) browser-login fallback; its
    // primary path is a pasted coding-plan key. Kimi/MiniMax are stateless (key/token paste).
    let zai = ZaiCollector()

    /// The active collectors, in display order, filtered to the providers the user has
    /// enabled. Stateless ones (Claude/Codex/MiniMax/Kimi) are rebuilt each call so they
    /// pick up pref changes (e.g. Claude's extra-usage opt-in) with no restart.
    private var collectors: [any Collector] {
        let all: [any Collector] = [
            ClaudeCollector(includeExtraUsage: prefs.showClaudeExtraUsage),
            CodexCollector(),
            MiniMaxCollector(),
            zai,
            KimiCollector(),
            GrokCollector(),
        ]
        return all.filter { prefs.isEnabled($0.id) }
    }

    /// The WKWebView to host for a given provider's in-app login, if it has one. Only z.ai
    /// keeps one (browser-login fallback); everyone else uses local creds or a paste.
    func loginWebView(for id: String) -> WKWebView? {
        id == zai.id ? zai.loginWebView : nil
    }

    /// Kick off navigation to the provider's login/usage page in its webview.
    func startLogin(_ id: String) {
        if id == zai.id { zai.startLogin() }
    }

    private var refreshTask: Task<Void, Never>?

    /// Last reading that actually had meters, per provider. A failed refresh falls back
    /// to this (marked `.stale`) instead of flashing the card to an empty error.
    private var lastGood: [String: ProviderUsage] = [:]

    /// Provider *service* health (is their API up), from the public status pages — distinct
    /// from usage. Only providers with a status page populate; others stay absent (no dot).
    var serviceHealth: [String: ServiceHealth] = [:]
    @ObservationIgnored private var lastStatusCheck: Date?

    /// When each provider was last polled — drives cadence-aware refresh (local providers
    /// every tick, remote ones at half the rate).
    @ObservationIgnored private var lastCollected: [String: Date] = [:]
    /// Most recent reading per provider; rebuilt into `usages` (display order) each tick so
    /// a provider skipped this cycle keeps showing its last value instead of vanishing.
    @ObservationIgnored private var current: [String: ProviderUsage] = [:]

    @ObservationIgnored private let notifier = Notifier()
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    init() {
        // Seed the menu-bar glyph immediately at construction so a hat is visible the moment
        // the app launches — NOT deferred to start()/the popover's .task. Without this the
        // stored menuBarItems would be empty until the popover is first opened, and the
        // menu-bar item renders nothing (looks like the app didn't launch).
        recomputeMenuBar()
    }

    func start() {
        guard refreshTask == nil else { return }
        notifier.requestAuthorizationIfNeeded()
        updater.automaticallyChecksForUpdates = prefs.autoUpdate   // Sparkle's schedule mirrors the pref
        recomputeMenuBar()   // re-seed the glyph state before the first refresh lands
        observeWake()
        warmHistory()   // precompute the History window's data so it opens instantly
        refreshTask = Task { [weak self] in
            var first = true
            while !Task.isCancelled {
                await self?.refresh(force: first)   // force the initial load; then honor cadence
                first = false
                // Re-read the interval each cycle so a Settings change takes effect next tick.
                let mins = self?.prefs.refreshMinutes ?? 15
                try? await Task.sleep(for: .seconds(max(1, mins) * 60))
            }
        }
    }

    /// Refresh on wake from sleep (debounced) — a menu-bar app that's stale after the lid
    /// reopens feels broken. Honors the user's `refreshOnWake` pref.
    private func observeWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.prefs.refreshOnWake else { return }
                    await self.refreshIfStale()
                }
            }
    }

    func stop() { refreshTask?.cancel(); refreshTask = nil }

    /// Refresh immediately if it's been at least a minute (debounce wake/manual storms).
    func refreshIfStale(minGap: TimeInterval = 60) async {
        if let last = lastRefresh, Date().timeIntervalSince(last) < minGap { return }
        await refresh()
    }

    /// Refresh providers that are due, or all of them when `force` is true (the initial
    /// load, the manual button, a key/enable change, a wake refresh). Cadence-aware: local
    /// collectors poll at the base interval; remote ones at half the rate (`RefreshCadence`).
    /// A provider skipped this cycle keeps its last reading rather than blanking.
    func refresh(force: Bool = true) async {
        isRefreshing = true
        defer { isRefreshing = false }
        let now = Date()
        let base = TimeInterval(max(1, prefs.refreshMinutes) * 60)
        let active = collectors
        let activeIDs = Set(active.map { $0.id })
        var collectedAny = false
        for c in active {
            let due = force || {
                guard let last = lastCollected[c.id] else { return true }   // never polled → due
                return now.timeIntervalSince(last) >= c.cadence.interval(base: base) - 5
            }()
            guard due else { continue }
            collectedAny = true
            do {
                let fresh = try await c.collect()
                if fresh.status == .ok, !fresh.metrics.isEmpty {
                    lastGood[c.id] = fresh          // remember good readings
                }
                current[c.id] = fresh
            } catch {
                // Don't blank the card: re-show the last good reading, dimmed + dated.
                if var stale = lastGood[c.id] {
                    stale.status = .stale
                    current[c.id] = stale
                } else {
                    current[c.id] = ProviderUsage(provider: c.id, displayName: c.displayName, status: .error)
                }
            }
            lastCollected[c.id] = now
        }
        // Drop providers the user turned off; render the rest in display order.
        current = current.filter { activeIDs.contains($0.key) }
        lastCollected = lastCollected.filter { activeIDs.contains($0.key) }
        usages = active.compactMap { current[$0.id] }
        recomputeMenuBar()                   // keep the menu-bar glyph synced to fresh usages
        refreshServiceHealth(now)            // check status pages (throttled, off the UI path)
        guard collectedAny else { return }   // an empty tick (nothing due) changes nothing
        lastRefresh = now
        UsageHistory.shared.record(usages)   // append today's reading for trend/heatmap
        warmHistory()                         // keep the History window's cache fresh
        notifier.evaluate(usages, thresholds: prefs.notifyThresholds, enabled: prefs.notify,
                          sound: prefs.notifySound, onReset: prefs.notifyOnReset)
    }

    /// Fetch provider service health from the public status pages, throttled to every 5 min
    /// (incidents move slowly). Off the main refresh path so a slow status page never delays
    /// the usage cards. Disabled → clears the map (offline/opted-out shows no dots).
    private func refreshServiceHealth(_ now: Date) {
        guard prefs.checkProviderStatus else { serviceHealth = [:]; lastStatusCheck = nil; return }
        if let last = lastStatusCheck, now.timeIntervalSince(last) < 300 { return }
        let ids = collectors.map(\.id).filter { ProviderStatus.statusURL(for: $0) != nil }
        guard !ids.isEmpty else { return }
        lastStatusCheck = now
        Task { [weak self] in
            var next: [String: ServiceHealth] = [:]
            await withTaskGroup(of: (String, ServiceHealth).self) { group in
                for id in ids { group.addTask { (id, await ProviderStatus.fetch(for: id)) } }
                for await (id, h) in group { next[id] = h }
            }
            await MainActor.run { self?.serviceHealth = next }
        }
    }

    // MARK: - paste-once API keys (web/key providers)

    /// Headroom-owned keychain service for a provider's pasted key, or nil if the
    /// provider uses local creds (Claude/Codex) or has no collector yet.
    func keyService(for id: String) -> String? {
        switch id {
        case "zai":     ZaiCollector.keyService
        case "minimax": MiniMaxCollector.keyService
        case "kimi":    KimiCollector.keyService   // pasted session token
        default:        nil   // claude/codex use local creds
        }
    }

    func hasStoredKey(for id: String) -> Bool {
        guard let svc = keyService(for: id) else { return false }
        return LocalKey.stored(service: svc) != nil
    }

    /// Save a pasted key and refresh so the provider lights up immediately.
    func saveKey(_ key: String, for id: String) {
        guard let svc = keyService(for: id) else { return }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        LocalKey.store(trimmed, service: svc)
        Task { await refresh() }
    }

    func clearKey(for id: String) {
        guard let svc = keyService(for: id) else { return }
        LocalKey.clearStored(service: svc)
        Task { await refresh() }
    }

    /// Toggle a provider on/off and refresh so a newly-enabled provider appears
    /// immediately (its card was absent because the last refresh predated the toggle).
    /// Turning one off drops its card on the same refresh.
    func setEnabled(_ id: String, _ on: Bool) {
        prefs.setEnabled(id, on)
        Task { await refresh() }
    }

    var needsAnyLogin: Bool { usages.contains { $0.status == .needsLogin } }

    /// Blended capacity across every provider — the at-a-glance "3 comfortable · 1 tight"
    /// only a multi-provider tool can give. Derived live from current usages.
    var blendedCapacity: CapacitySummary { CapacitySummary.from(usages) }

    /// What refills when, soonest first. Powers the History window's reset timeline.
    var resetTimeline: [ResetEntry] { ResetTimeline.from(usages) }

    /// Tightest authoritative fraction (0...1) over a set of usages.
    private func tightest(in list: [ProviderUsage]) -> Double? {
        list.flatMap { $0.metrics }.filter { $0.authoritative }
            .compactMap { $0.fractionUsed }.max()
    }

    /// Tightest authoritative fraction for one provider.
    func fraction(forProvider id: String) -> Double? {
        tightest(in: usages.filter { $0.id == id })
    }

    /// The signature multi-provider move: when your hottest subscription is running low,
    /// point at the one with the most headroom left. Only a multi-provider tool can answer
    /// "you're nearly out of Claude — switch to GLM." Surfaces only when it's actionable:
    /// the tightest meter is genuinely hot and another live provider is meaningfully roomier.
    struct NextPick: Equatable {
        let hotName: String;  let hotFraction: Double
        let roomName: String; let roomFraction: Double
    }
    /// Tunables for the hint. Tightest must be at/above `hotThreshold`, and the roomy
    /// provider at least `minGap` lower, before we nudge.
    var useThisNext: NextPick? {
        // tightest authoritative fraction per OK provider that actually has a capped meter
        let perProvider: [(name: String, frac: Double)] = usages.compactMap { u in
            guard u.status == .ok || u.status == .stale, let f = fraction(forProvider: u.id) else { return nil }
            return (u.displayName, f)
        }
        guard perProvider.count >= 2,
              let hot = perProvider.max(by: { $0.frac < $1.frac }), hot.frac >= 0.80,
              let room = perProvider.filter({ $0.name != hot.name }).min(by: { $0.frac < $1.frac }),
              room.frac <= hot.frac - 0.20 else { return nil }
        return NextPick(hotName: hot.name, hotFraction: hot.frac,
                        roomName: room.name, roomFraction: room.frac)
    }

    /// Non-unlimited capped meters for a provider, in report order — the meters a user
    /// could pin to the menu bar.
    func pinnableMeters(forProvider id: String) -> [Metric] {
        usages.first { $0.id == id }?.metrics.filter { !$0.unlimited && $0.fractionUsed != nil } ?? []
    }

    /// The fraction the menu bar should show for a provider, honoring a pinned meter when
    /// one is set and present; otherwise the provider's tightest meter. Returns the
    /// resolved meter's label too (for the VoiceOver string). Distinct from
    /// `fraction(forProvider:)`, which is always tightest (the "use this next" hint wants
    /// the worst meter regardless of what's pinned in the menu bar).
    private func menuBarFraction(forProvider id: String) -> (fraction: Double?, label: String?) {
        if let pinned = prefs.pinnedMeters[id],
           let m = pinnableMeters(forProvider: id).first(where: { $0.label == pinned }) {
            return (m.fractionUsed, m.label)
        }
        return (fraction(forProvider: id), nil)   // tightest; label nil = "tightest meter"
    }

    /// One entry per hat the menu bar should draw, in the user's chosen order. A single
    /// entry for tightest/hat-only; up to three for the multi-provider bar. `id` is
    /// "_tightest" for the aggregate hat (no specific provider). `meterLabel` is the
    /// pinned meter's name when one resolved, else nil (tightest).
    struct GlyphItem: Identifiable { let id: String; let fraction: Double?; var meterLabel: String? = nil }

    /// Build the menu-bar items for the current glyph source. The source of truth that
    /// `recomputeMenuBar` snapshots into the stored `menuBarItems`.
    private func computeGlyphItems() -> [GlyphItem] {
        switch prefs.glyphSource {
        case .tightest, .hatOnly:
            return [GlyphItem(id: "_tightest", fraction: tightest(in: usages))]
        case .providers(let ids):
            let live = ids.filter { prefs.isEnabled($0) }
            let pick = live.isEmpty ? ids : live   // if none enabled, still show what was chosen
            return pick.prefix(GlyphSource.maxProviders).map { id in
                let r = menuBarFraction(forProvider: id)
                return GlyphItem(id: id, fraction: r.fraction, meterLabel: r.label)
            }
        }
    }

    /// Snapshot the glyph prefs + current usages into the stored menu-bar state. Called on
    /// every refresh (after `usages` updates) and from each glyph-pref setter, so a Settings
    /// change reflects in the menu bar immediately — no refresh tick, no restart.
    func recomputeMenuBar() {
        menuBarItems = computeGlyphItems()
        menuBarStyle = prefs.glyphStyle
        if case .hatOnly = prefs.glyphSource { menuBarShowsPercent = false } else { menuBarShowsPercent = true }
        menuBarFlame = prefs.showPeakHours && prefs.peakHoursFlame && PeakHours.isPeak()
        // Composite the whole label into one image so the MenuBarExtra reliably swaps it.
        menuBarImage = MenuBarGlyph.compose(items: menuBarItems, showPercent: menuBarShowsPercent,
                                            style: menuBarStyle, flame: menuBarFlame)
        menuBarA11y = MenuBarGlyph.a11y(items: menuBarItems)
    }

    // MARK: glyph-pref setters (route through here so the menu bar recomputes live)

    func setGlyphSource(_ source: GlyphSource) { prefs.glyphSource = source; recomputeMenuBar() }
    func setGlyphStyle(_ style: GlyphStyle)    { prefs.glyphStyle = style; recomputeMenuBar() }
    /// Pin a provider's menu-bar meter to `label`, or nil to clear (back to tightest).
    func setPinnedMeter(_ id: String, label: String?) {
        if let label { prefs.pinnedMeters[id] = label } else { prefs.pinnedMeters[id] = nil }
        recomputeMenuBar()
    }
}
