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

    /// The most recent adaptive-cadence decision (delay + reason), or nil in fixed-interval
    /// mode. Observable so the Settings "Adaptive refresh" row can show the live cadence
    /// ("Currently every 2 min · you just looked"). Recomputed each loop tick.
    var adaptiveDecision: AdaptiveCadence.Decision?

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

    /// Warm cache of each spend provider's Today/7d/30d summary (estimated from local logs
    /// at list rates). Computed off-main like `historyTokensByProvider`: the History
    /// window's Spend panel reads this and never blocks on a scan. The per-file
    /// `SpendScanCache` makes repeat scans cheap (only changed files re-parse), so this
    /// can refresh every cycle; the ~70s cold scan happens once, off the UI path.
    var spendSummaries: [String: SpendUsage.Summary] = [:]
    @ObservationIgnored private var spendWarming = false

    /// Kick a background spend scan into the warm cache. Coalesced like `warmHistory`.
    func warmSpend(days: Int = 30) {
        guard !spendWarming else { return }
        spendWarming = true
        Task.detached(priority: .utility) { [weak self] in
            let pricing = await ModelPricing.load()
            var next: [String: SpendUsage.Summary] = [:]
            await withTaskGroup(of: (String, SpendUsage.Summary).self) { group in
                for (id, pricingProvider) in SpendUsage.providers {
                    group.addTask {
                        let cache = SpendScanCache.load(provider: id)
                        let (daily, updated) = id == "claude"
                            ? await SpendUsage.claudeDaily(days: days, cache: cache)
                            : await SpendUsage.codexDaily(days: days, cache: cache)
                        updated.save(provider: id)
                        return (id, SpendUsage.summarize(daily, provider: pricingProvider, pricing: pricing))
                    }
                }
                for await (id, s) in group { next[id] = s }
            }
            let summaries = next
            await MainActor.run { [weak self] in
                self?.spendSummaries = summaries
                self?.spendWarming = false
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

    // MARK: - Claude multi-account (dynamic N accounts; capture/switch in-app via `ClaudeAccounts`)

    /// The label of the account currently in the live slot (nil when a single-account user has
    /// never captured — the base `claude` card just reads the live login).
    ///
    /// SNAPSHOTTED, not read per access. It used to hit the pointer file on every get, and
    /// `collectors` reads it twice (once for the base card, once through `discoveredClaudeIDs`).
    /// A switch landing between those two reads tore the render: the base card labelled from
    /// the OLD pointer while the filter used the NEW one, so the same account appeared as two
    /// cards — one "ACTIVE", one offering "Switch" to itself, both showing identical numbers.
    /// One value per render is the fix.
    private(set) var activeClaudeLabel: String? = ClaudeAccounts.loadIndex().activeLabel

    /// All captured account labels, cached so SwiftUI renders and refresh ticks don't each
    /// spawn a `security dump-keychain`. Refreshed on every poll and after any account op.
    private(set) var claudeAccountLabels: [String] = ClaudeAccounts.listLabels()
    private func refreshClaudeAccountLabels() {
        claudeAccountLabels = ClaudeAccounts.listLabels()
        activeClaudeLabel = ClaudeAccounts.loadIndex().activeLabel
    }

    /// Extra Claude account ids beyond the base `claude` — one `claude-acct-<label>` per
    /// stash that isn't the live account. Drives the collectors, Settings, and menu-bar.
    var discoveredClaudeIDs: [String] {
        let active = activeClaudeLabel
        return claudeAccountLabels
            .filter { $0 != active }
            .map(ClaudeAccounts.providerID(forLabel:))
    }

    /// Base providers plus any discovered Claude account cards, in display order — for the
    /// Settings provider list and the menu-bar "specific providers" picker.
    var allProviderIDsForDisplay: [String] {
        var ids = Prefs.allProviderIDs
        let insertAt = (ids.firstIndex(of: "claude").map { $0 + 1 }) ?? ids.count
        ids.insert(contentsOf: discoveredClaudeIDs, at: insertAt)
        return ids
    }

    /// More than one Claude account exists (the live one + at least one stash) — gates the
    /// in-card Switch/ACTIVE chip, which only makes sense when there's somewhere to switch.
    var isMultiAccountClaude: Bool { !discoveredClaudeIDs.isEmpty }

    /// Build a ClaudeCollector for one account. The ACTIVE account reads Claude Code's live
    /// slot (the CLI keeps it fresh); an INACTIVE account reads its Headroom-owned stash
    /// (frozen at last capture → token expires → the card shows last-known, dimmed).
    private func claudeCollector(id: String, label: String?, isActive: Bool) -> ClaudeCollector {
        // Base "Claude" while there's only one account; label each card once there are more.
        let display: String = (isMultiAccountClaude && label != nil)
            ? "Claude · \(prefs.claudeAccountDisplayName(label!))" : "Claude"
        return ClaudeCollector(
            id: id, displayName: display,
            credentialsPath: isActive ? nil : URL(fileURLWithPath: "/dev/null"),
            keychainService: isActive ? ClaudeAccounts.liveService : ClaudeAccounts.stashPrefix + (label ?? ""),
            includeExtraUsage: prefs.showClaudeExtraUsage)
    }

    /// The active collectors, in display order, filtered to the providers the user has
    /// enabled. Stateless ones (Claude/Codex/MiniMax/Kimi) are rebuilt each call so they
    /// pick up pref changes (e.g. Claude's extra-usage opt-in, or an account switch) with no restart.
    private var collectors: [any Collector] {
        var all: [any Collector] = [
            claudeCollector(id: "claude", label: activeClaudeLabel, isActive: true),
            CodexCollector(),
            MiniMaxCollector(),
            zai,
            KimiCollector(),
            GrokCollector(),
        ]
        // One card per non-active stash, inserted right after the base Claude card.
        for (i, accID) in discoveredClaudeIDs.enumerated() {
            let label = ClaudeAccounts.label(forProviderID: accID)
            all.insert(claudeCollector(id: accID, label: label, isActive: false), at: 1 + i)
        }
        return all.filter { prefs.isEnabled($0.id) }
    }

    /// Flip the live Claude account (in-app, no shell-out), then refresh so the cards swap
    /// their live/last-known roles. Takes effect for NEW `claude` sessions. The Keychain
    /// write runs off the main actor: modifying the live slot can show a one-time macOS
    /// authorization prompt, which must never freeze the UI while it waits.
    func switchClaudeAccount(_ label: String) {
        Task {
            _ = await Task.detached(priority: .userInitiated) { await ClaudeAccounts.switchTo(label) }.value
            refreshClaudeAccountLabels()
            await refresh()
        }
    }

    /// Capture the currently-logged-in Claude account under a user-typed name: stash it,
    /// remember the nice display name, enable its card, refresh. Returns a message to show.
    /// Keychain work runs off the main actor (see `switchClaudeAccount`).
    func captureClaudeAccount(name: String) async -> Result<String, ClaudeAccounts.OpError> {
        let r = await Task.detached(priority: .userInitiated) { await ClaudeAccounts.capture(label: name) }.value
        if case .success = r, let label = ClaudeAccounts.sanitizeLabel(name) {
            let nice = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !nice.isEmpty { prefs.claudeAccountNames[label] = nice }
            prefs.setEnabled(ClaudeAccounts.providerID(forLabel: label), true)
            refreshClaudeAccountLabels()
            Task { await refresh() }
        }
        return r
    }

    /// Remove a saved (non-active) Claude account stash + its display name, then refresh.
    /// Keychain work runs off the main actor (see `switchClaudeAccount`).
    func removeClaudeAccount(_ label: String) async -> Result<String, ClaudeAccounts.OpError> {
        let r = await Task.detached(priority: .userInitiated) { ClaudeAccounts.remove(label) }.value
        if case .success = r {
            prefs.claudeAccountNames[label] = nil
            refreshClaudeAccountLabels()
            Task { await refresh() }
        }
        return r
    }

    /// For a Claude card: the switch label + whether it's the live account, or nil for
    /// non-Claude cards / single-account setups. Drives the card's Switch/ACTIVE chip.
    func claudeSwitchInfo(for id: String) -> (label: String, isActive: Bool)? {
        guard isMultiAccountClaude else { return nil }
        if id == "claude" {
            guard let active = activeClaudeLabel else { return nil }
            return (active, true)                       // the base card is the live account
        }
        if let label = ClaudeAccounts.label(forProviderID: id) {
            return (label, false)                       // a stash card is never the live account
        }
        return nil
    }

    // MARK: - last-good persistence

    /// Where per-provider last-good snapshots live (real ~/Library — the app is unsandboxed,
    /// same as history.json).
    private var lastGoodDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Headroom/lastgood", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Persist a good reading so it survives relaunch — the inactive Claude account (whose
    /// stash token has expired) then shows its last real gauges instead of "No meters reported".
    private func persistLastGood(_ u: ProviderUsage) {
        guard let data = try? JSONEncoder().encode(u) else { return }
        try? data.write(to: lastGoodDir.appendingPathComponent("\(u.id).json"), options: .atomic)
    }

    /// Load persisted last-good readings into memory before the first poll, so a just-launched
    /// or inactive meter falls back to last-known rather than an empty card.
    private func rehydrateLastGood() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: lastGoodDir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "json" {
            if let data = try? Data(contentsOf: f),
               let u = try? JSONDecoder().decode(ProviderUsage.self, from: data) {
                lastGood[u.id] = u
            }
        }
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
    /// When the menu-bar popover was last opened, this launch only. In-memory, never
    /// persisted (resets each launch) — feeds `AdaptiveCadence` so polling stays fast while
    /// you're actively looking and coasts once you step away.
    @ObservationIgnored private var lastMenuOpenAt: Date?
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
        warmSpend()     // precompute the Spend panel (cold scan once, warm afterwards)
        rehydrateLastGood()   // seed last-known so the first poll of an inactive account isn't a blank card
        refreshTask = Task { [weak self] in
            var first = true
            while !Task.isCancelled {
                // One base interval per cycle, used for BOTH this refresh's per-provider
                // due-check and the sleep after it — so a fixed slider change (or the adaptive
                // decision) takes effect on the same tick, and remote providers' relaxed
                // cadence stays "half of whatever the base is right now".
                let base = self?.nextBaseInterval() ?? 15 * 60
                await self?.refresh(force: first, base: base)
                first = false
                try? await Task.sleep(for: .seconds(base))
            }
        }
    }

    /// The base refresh interval for the next cycle. In adaptive mode, decides from live Low
    /// Power / thermal state + interaction recency (`AdaptiveCadence`) and records the
    /// decision for the Settings display; in fixed mode, the user's slider value. This is
    /// also the `base` the per-provider `.relaxed` cadence is measured against.
    func nextBaseInterval() -> TimeInterval {
        guard prefs.adaptiveRefresh else {
            adaptiveDecision = nil
            return TimeInterval(max(1, prefs.refreshMinutes) * 60)
        }
        let pi = ProcessInfo.processInfo
        let thermal = pi.thermalState == .serious || pi.thermalState == .critical
        let d = AdaptiveCadence.decide(.init(now: Date(), lastMenuOpenAt: lastMenuOpenAt,
                                             lowPowerMode: pi.isLowPowerModeEnabled,
                                             thermalConstrained: thermal))
        adaptiveDecision = d
        return d.delay
    }

    /// Record a menu-bar popover open. Feeds `AdaptiveCadence` (recency band) so the next
    /// tick tightens to the fast cadence, and freshens data on look via `refreshIfStale`.
    /// Called from the popover's `.onAppear`.
    func noteMenuOpened() {
        lastMenuOpenAt = Date()
        Task { await refreshIfStale() }
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

    /// Refresh immediately if it's been at least a minute (debounce wake/menu-open/manual
    /// storms), unless one is already in flight — the running refresh will deliver fresh data
    /// momentarily, so a second one would only pile on at an await boundary.
    func refreshIfStale(minGap: TimeInterval = 60) async {
        if isRefreshing { return }
        if let last = lastRefresh, Date().timeIntervalSince(last) < minGap { return }
        await refresh()
    }

    /// Refresh providers that are due, or all of them when `force` is true (the initial
    /// load, the manual button, a key/enable change, a wake refresh). Cadence-aware: local
    /// collectors poll at the base interval; remote ones at half the rate (`RefreshCadence`).
    /// A provider skipped this cycle keeps its last reading rather than blanking.
    func refresh(force: Bool = true, base: TimeInterval? = nil) async {
        isRefreshing = true
        defer { isRefreshing = false }
        refreshClaudeAccountLabels()   // pick up accounts captured/removed outside the app (e.g. the CLI)
        let now = Date()
        // The per-provider due-check is measured against this base. The loop passes the
        // cycle's base (fixed or adaptive); non-loop callers (manual, wake, key/enable)
        // force a refresh, so `base` is unused there and just defaults to the slider value.
        let base = base ?? TimeInterval(max(1, prefs.refreshMinutes) * 60)
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
                    persistLastGood(fresh)          // survive relaunch → inactive meter shows last-known
                    current[c.id] = fresh
                } else if fresh.status == .needsLogin, lastGood[c.id] == nil {
                    current[c.id] = fresh           // genuinely unauthenticated → show the login/paste UI
                } else if var stale = lastGood[c.id] {
                    // A non-ok / empty reading (a 401 during Claude token rotation, or an inactive
                    // account's expired stash) must NOT blank the card — re-show last-good, dimmed.
                    stale.status = .stale
                    current[c.id] = stale
                } else {
                    current[c.id] = fresh           // no prior good reading — show whatever we got
                }
            } catch {
                // Network error thrown: same fallback.
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
        BurnSampler.shared.record(usages)    // append (t, fraction) burn samples for the burn-down chart
        warmHistory()                         // keep the History window's cache fresh
        warmSpend()                           // keep the Spend panel fresh (cheap on a warm cache)
        notifier.evaluate(usages, thresholds: prefs.notifyThresholds, enabled: prefs.notify,
                          sound: prefs.notifySound, onReset: prefs.notifyOnReset,
                          onDeplete: prefs.notifyOnDeplete, onPace: prefs.notifyOnPace,
                          snoozeUntil: prefs.snoozeUntil)
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

    /// Tightest authoritative metric over a set of usages (the meter behind the fraction —
    /// carries `resetAt` for the exhausted-countdown swap).
    private func tightestMetric(in list: [ProviderUsage]) -> Metric? {
        list.flatMap { $0.metrics }
            .filter { $0.authoritative && $0.fractionUsed != nil }
            .max { ($0.fractionUsed ?? 0) < ($1.fractionUsed ?? 0) }
    }

    /// Tightest authoritative fraction (0...1) over a set of usages.
    private func tightest(in list: [ProviderUsage]) -> Double? {
        tightestMetric(in: list)?.fractionUsed
    }

    /// Tightest authoritative fraction for one provider.
    func fraction(forProvider id: String) -> Double? {
        tightest(in: usages.filter { $0.id == id })
    }

    /// The tightest authoritative metric for one provider — the meter a glance row shows
    /// (fraction + its reset), same resolution the menu bar's tightest mode uses.
    func glanceMetric(forProvider id: String) -> Metric? {
        tightestMetric(in: usages.filter { $0.id == id })
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
    private func menuBarFraction(forProvider id: String) -> (fraction: Double?, label: String?, resetAt: Date?) {
        if let pinned = prefs.pinnedMeters[id],
           let m = pinnableMeters(forProvider: id).first(where: { $0.label == pinned }) {
            return (m.fractionUsed, m.label, m.resetAt)
        }
        let m = tightestMetric(in: usages.filter { $0.id == id })
        return (m?.fractionUsed, nil, m?.resetAt)   // tightest; label nil = "tightest meter"
    }

    /// One entry per hat the menu bar should draw, in the user's chosen order. A single
    /// entry for tightest/hat-only; up to three for the multi-provider bar. `id` is
    /// "_tightest" for the aggregate hat (no specific provider). `meterLabel` is the
    /// pinned meter's name when one resolved, else nil (tightest). `resetAt` is the
    /// resolved meter's reset, for the exhausted-countdown swap.
    struct GlyphItem: Identifiable {
        let id: String; let fraction: Double?
        var meterLabel: String? = nil
        var resetAt: Date? = nil
    }

    /// Build the menu-bar items for the current glyph source. The source of truth that
    /// `recomputeMenuBar` snapshots into the stored `menuBarItems`.
    private func computeGlyphItems() -> [GlyphItem] {
        switch prefs.glyphSource {
        case .tightest, .hatOnly:
            let m = tightestMetric(in: usages)
            return [GlyphItem(id: "_tightest", fraction: m?.fractionUsed, resetAt: m?.resetAt)]
        case .mostUsed:
            // Auto-pick the hottest PROVIDER (not just the hottest meter) so the item carries
            // an identity — the monogram style then names who's burning, hands-free.
            let hottest = usages
                .compactMap { u -> (id: String, m: Metric)? in
                    tightestMetric(in: [u]).map { (u.id, $0) }
                }
                .max { ($0.m.fractionUsed ?? 0) < ($1.m.fractionUsed ?? 0) }
            guard let hottest else { return [GlyphItem(id: "_tightest", fraction: nil)] }
            return [GlyphItem(id: hottest.id, fraction: hottest.m.fractionUsed,
                              resetAt: hottest.m.resetAt)]
        case .providers(let ids):
            let live = ids.filter { prefs.isEnabled($0) }
            let pick = live.isEmpty ? ids : live   // if none enabled, still show what was chosen
            return pick.prefix(GlyphSource.maxProviders).map { id in
                let r = menuBarFraction(forProvider: id)
                return GlyphItem(id: id, fraction: r.fraction, meterLabel: r.label, resetAt: r.resetAt)
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
                                            style: menuBarStyle, flame: menuBarFlame,
                                            resetWhenExhausted: prefs.resetWhenExhausted,
                                            showRemaining: prefs.menuBarShowsRemaining)
        menuBarA11y = MenuBarGlyph.a11y(items: menuBarItems, showRemaining: prefs.menuBarShowsRemaining)
    }

    // MARK: glyph-pref setters (route through here so the menu bar recomputes live)

    func setGlyphSource(_ source: GlyphSource) { prefs.glyphSource = source; recomputeMenuBar() }
    func setGlyphStyle(_ style: GlyphStyle)    { prefs.glyphStyle = style; recomputeMenuBar() }
    func setResetWhenExhausted(_ on: Bool)     { prefs.resetWhenExhausted = on; recomputeMenuBar() }
    func setMenuBarShowsRemaining(_ on: Bool)  { prefs.menuBarShowsRemaining = on; recomputeMenuBar() }
    /// Pin a provider's menu-bar meter to `label`, or nil to clear (back to tightest).
    func setPinnedMeter(_ id: String, label: String?) {
        if let label { prefs.pinnedMeters[id] = label } else { prefs.pinnedMeters[id] = nil }
        recomputeMenuBar()
    }
}
