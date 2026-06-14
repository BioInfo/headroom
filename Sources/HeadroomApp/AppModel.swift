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

    /// Which provider the login window should authenticate. Set when a card's
    /// "Log in" button is tapped, read by the login window to pick the webview.
    var loginTargetID: String?

    let prefs = Prefs.shared

    // Web/stateful collectors held as instances (their WKWebView persists the session).
    let zai = ZaiCollector()
    let kimi = KimiCollector()

    /// The active collectors, in display order, filtered to the providers the user has
    /// enabled. Stateless ones (Claude/Codex/MiniMax) are rebuilt each call so they pick
    /// up pref changes (e.g. Claude's extra-usage opt-in) with no restart.
    private var collectors: [any Collector] {
        let all: [any Collector] = [
            ClaudeCollector(includeExtraUsage: prefs.showClaudeExtraUsage),
            CodexCollector(),
            MiniMaxCollector(),
            zai,
            kimi,
        ]
        return all.filter { prefs.isEnabled($0.id) }
    }

    /// The WKWebView to host for a given web provider's in-app login, if it has one.
    /// (Claude + Codex + MiniMax read local creds/keys, so they have no login webview.)
    func loginWebView(for id: String) -> WKWebView? {
        switch id {
        case zai.id:  return zai.loginWebView
        case kimi.id: return kimi.loginWebView
        default:      return nil
        }
    }

    /// Kick off navigation to the provider's login/usage page in its webview.
    func startLogin(_ id: String) {
        switch id {
        case zai.id:  zai.startLogin()
        case kimi.id: kimi.startLogin()
        default:      break
        }
    }

    private var refreshTask: Task<Void, Never>?

    /// Last reading that actually had meters, per provider. A failed refresh falls back
    /// to this (marked `.stale`) instead of flashing the card to an empty error.
    private var lastGood: [String: ProviderUsage] = [:]

    @ObservationIgnored private let notifier = Notifier()
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    func start() {
        guard refreshTask == nil else { return }
        notifier.requestAuthorizationIfNeeded()
        observeWake()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
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

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false; lastRefresh = Date() }
        var next: [ProviderUsage] = []
        for c in collectors {
            do {
                let fresh = try await c.collect()
                if fresh.status == .ok, !fresh.metrics.isEmpty {
                    lastGood[c.id] = fresh          // remember good readings
                }
                next.append(fresh)
            } catch {
                // Don't blank the card: re-show the last good reading, dimmed + dated.
                if var stale = lastGood[c.id] {
                    stale.status = .stale
                    next.append(stale)
                } else {
                    next.append(ProviderUsage(provider: c.id, displayName: c.displayName, status: .error))
                }
            }
        }
        usages = next
        UsageHistory.shared.record(next)   // append today's reading for trend/heatmap
        notifier.evaluate(next, thresholds: prefs.notifyThresholds, enabled: prefs.notify)
    }

    // MARK: - paste-once API keys (web/key providers)

    /// Headroom-owned keychain service for a provider's pasted key, or nil if the
    /// provider uses local creds (Claude/Codex) or has no collector yet.
    func keyService(for id: String) -> String? {
        switch id {
        case "zai":     ZaiCollector.keyService
        case "minimax": MiniMaxCollector.keyService
        default:        nil   // claude/codex local; kimi webview-only (no key)
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

    var needsAnyLogin: Bool { usages.contains { $0.status == .needsLogin } }

    /// Tightest authoritative fraction (0...1) over a set of usages.
    private func tightest(in list: [ProviderUsage]) -> Double? {
        list.flatMap { $0.metrics }.filter { $0.authoritative }
            .compactMap { $0.fractionUsed }.max()
    }

    /// Tightest authoritative fraction for one provider.
    func fraction(forProvider id: String) -> Double? {
        tightest(in: usages.filter { $0.id == id })
    }

    /// What the single-hat glyph fills/labels to (tightest + hat-only modes). For the
    /// multi-provider mode this is the hottest of the chosen providers, used as a fallback.
    var tightestFractionUsed: Double? {
        switch prefs.glyphSource {
        case .tightest, .hatOnly:
            return tightest(in: usages)
        case .providers(let ids):
            return tightest(in: usages.filter { ids.contains($0.id) })
        }
    }

    /// One entry per hat the menu bar should draw, in the user's chosen order. A single
    /// entry for tightest/hat-only; up to three for the multi-provider bar. `id` is nil
    /// for the aggregate "tightest" hat (no specific provider).
    struct GlyphItem: Identifiable { let id: String; let fraction: Double? }
    var glyphItems: [GlyphItem] {
        switch prefs.glyphSource {
        case .tightest, .hatOnly:
            return [GlyphItem(id: "_tightest", fraction: tightest(in: usages))]
        case .providers(let ids):
            let live = ids.filter { prefs.isEnabled($0) }
            let pick = live.isEmpty ? ids : live   // if none enabled, still show what was chosen
            return pick.prefix(GlyphSource.maxProviders).map {
                GlyphItem(id: $0, fraction: fraction(forProvider: $0))
            }
        }
    }

    /// Whether to show the % text beside the hat (hidden in hat-only mode).
    var showGlyphPercent: Bool {
        if case .hatOnly = prefs.glyphSource { return false }
        return true
    }
}
