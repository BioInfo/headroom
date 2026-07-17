import SwiftUI
import WebKit
import HeadroomKit

// MARK: - Menu bar dropdown

struct MenuContent: View {
    @Bindable var model: AppModel
    /// Snapshot-harness override for the Overview (compact) mode — the harness must not
    /// write the user's real Prefs to render one panel compact. nil = follow the pref.
    var forceCompact: Bool? = nil
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var scheme

    private var isCompact: Bool { forceCompact ?? model.prefs.popoverCompact }

    /// Open one of our Window scenes from the menu-bar popover. An `.accessory` app
    /// isn't frontmost, so a bare `openWindow` lands the window BEHIND everything and
    /// looks dead — activate first, then nudge it to the front (mirrors the proven
    /// `--open` dev path).
    private func surface(_ id: String) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: id)
        // Front only the window we just opened, by title — `orderFrontRegardless` on ALL
        // windows would raise whatever else is open (e.g. History) on top of it.
        let title = Self.windowTitle(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            NSApp.activate(ignoringOtherApps: true)
            if let w = NSApp.windows.first(where: { $0.title == title }) {
                w.makeKeyAndOrderFront(nil)
            }
        }
    }

    private static func windowTitle(_ id: String) -> String {
        switch id {
        case "history":  "Usage History"
        case "settings": "Settings"
        case "login":    "Log in"
        default:         id
        }
    }

    /// Settings is a regular `Window(id: "settings")` (the `Settings` scene won't surface
    /// from an accessory MenuBarExtra app), so it opens the same proven way as the others.
    private func openSettings() { surface("settings") }

    var body: some View {
        let skin = Skin(model.prefs.effectiveScheme(scheme))
        VStack(alignment: .leading, spacing: 11) {
            // Dev: `--open <id>` opens that window on launch (for screenshots).
            Color.clear.frame(height: 0).task {
                if let id = AppLaunchFlags.openWindowID {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: id)
                    try? await Task.sleep(for: .milliseconds(800))
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.forEach { $0.orderFrontRegardless() }
                    if let shot = AppLaunchFlags.shootPath {
                        try? await Task.sleep(for: .milliseconds(1400))   // let async loads + Charts settle
                        WindowShooter.shoot(to: shot)
                    }
                }
            }
            HStack(spacing: 7) {
                ChefHat().fill(skin.clay).frame(width: 17, height: 17)
                Text("Headroom").font(.headline).foregroundStyle(skin.ink)
                Spacer()
                if model.isRefreshing {
                    ProgressView().controlSize(.small).tint(skin.clay)
                }
                Button { Task { await model.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless).tint(skin.clay).help("Refresh now")
            }

            if let phrase = model.blendedCapacity.phrase {
                CapacityRow(summary: model.blendedCapacity, phrase: phrase, skin: skin)
            }

            if let pick = model.useThisNext {
                UseThisNextBanner(pick: pick, skin: skin)
            }

            if model.usages.isEmpty {
                Text("No data yet.").foregroundStyle(skin.faint).font(.callout)
            }

            if isCompact {
                // Overview: one dense glance row per provider — badge · name · tightest %
                // · reset. The whole lineup in a hand-height popover; cards are a toggle away.
                VStack(spacing: 3) {
                    ForEach(model.usages) { usage in
                        GlanceRow(usage: usage, skin: skin,
                                  metric: model.glanceMetric(forProvider: usage.provider),
                                  health: model.serviceHealth[usage.provider],
                                  isActiveClaude: model.claudeSwitchInfo(for: usage.provider)?.isActive == true)
                    }
                }
            } else {
                ForEach(model.usages) { usage in
                    ProviderCard(usage: usage, skin: skin,
                                 health: model.serviceHealth[usage.provider],
                                 refreshing: model.isRefreshing,
                                 canWebLogin: model.loginWebView(for: usage.provider) != nil,
                                 canKey: model.keyService(for: usage.provider) != nil,
                                 peak: model.peakHoursActive && usage.provider.hasPrefix("claude"),
                                 claudeSwitch: model.claudeSwitchInfo(for: usage.provider),
                                 signedOut: model.isClaudeAccountSignedOut(usage.provider),
                                 onLogin: {
                        model.loginTargetID = usage.provider
                        surface("login")
                    },
                                 onSettings: { openSettings() })
                }
            }

            Rectangle().fill(skin.edge).frame(height: 1)
            HStack(spacing: 10) {
                if let t = model.lastRefresh {
                    Text("Updated \(t.formatted(.relative(presentation: .named)))")
                        .font(.caption2).foregroundStyle(skin.faint)
                }
                Spacer()
                Button { model.prefs.popoverCompact.toggle() } label: {
                    Image(systemName: isCompact ? "rectangle.grid.1x2" : "list.bullet")
                }
                .buttonStyle(.borderless).tint(skin.ink2)
                .help(isCompact ? "Show full cards" : "Overview — one line per provider")
                Button { surface("history") } label: { Image(systemName: "chart.bar.xaxis") }
                    .buttonStyle(.borderless).tint(skin.ink2).help("Usage history")
                Button { openSettings() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless).tint(skin.ink2).help("Settings")
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless).tint(skin.ink2).font(.caption)
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(skin.bg)
    }
}

// MARK: - Blended capacity (the at-a-glance cross-provider read)

/// One quiet line: "3 comfortable · 1 tight · 1 unlimited" — the whole point of a
/// multi-provider tool, summarized before you scan the cards. Tinted by the worst bucket
/// present so the line itself signals overall pressure.
struct CapacityRow: View {
    let summary: CapacitySummary
    let phrase: String
    let skin: Skin

    /// Color the leading dot by the hottest bucket present.
    private var tier: UsageTier {
        if summary.count(.tight) > 0 { return .pressing }
        if summary.count(.warming) > 0 { return .warming }
        return .healthy
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(skin.ramp(tier)).frame(width: 7, height: 7)
            Text(phrase).font(.caption).foregroundStyle(skin.ink2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Capacity across providers: \(phrase)")
    }
}

// MARK: - "Use this next" hint (the signature multi-provider nudge)

/// When the hottest subscription is low on headroom, point at the roomiest one. The one
/// thing a single-provider tracker structurally can't tell you.
struct UseThisNextBanner: View {
    let pick: AppModel.NextPick
    let skin: Skin
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.turn.down.right")
                .font(.caption.weight(.bold)).foregroundStyle(skin.ramp(.healthy))
            (Text(pick.hotName).fontWeight(.semibold)
             + Text(" \(Int((pick.hotFraction*100).rounded()))% used · most room: ")
             + Text(pick.roomName).fontWeight(.semibold)
             + Text(" \(Int((pick.roomFraction*100).rounded()))%"))
                .font(.caption).foregroundStyle(skin.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(skin.ramp(.healthy).opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(skin.ramp(.healthy).opacity(0.30), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Use this next: \(pick.hotName) is \(Int((pick.hotFraction*100).rounded())) percent used. Most room: \(pick.roomName) at \(Int((pick.roomFraction*100).rounded())) percent.")
    }
}

// MARK: - Overview glance row (compact popover mode)

/// One dense line per provider: badge · name · (ACTIVE) · health · tightest % in tier
/// color · compact reset. The whole point is height — seven providers in the space three
/// cards take. Click opens the provider's dashboard, same as a card header.
struct GlanceRow: View {
    let usage: ProviderUsage
    let skin: Skin
    var metric: Metric? = nil          // the provider's tightest meter (fraction + reset)
    var health: ServiceHealth? = nil
    var isActiveClaude: Bool = false

    private var dashboard: URL? { ProviderInfo.dashboardURL(usage.provider) }

    /// "45m" exhausted-countdown, else the tightest %, else a status word.
    private var reading: (text: String, color: Color) {
        if usage.status == .needsLogin { return ("log in", skin.clay) }
        guard let f = metric?.fractionUsed else { return ("—", skin.faint) }
        if let back = ExhaustedReset.countdown(fraction: f, resetAt: metric?.resetAt) {
            return (back, skin.ramp(metric?.severityFraction ?? f))
        }
        return ("\(Int((f * 100).rounded()))%", skin.ramp(metric?.severityFraction ?? f))
    }

    var body: some View {
        HStack(spacing: 7) {
            ProviderBadge(id: usage.provider, skin: skin, size: 15)
            Text(usage.displayName)
                .font(.caption.weight(.medium)).foregroundStyle(skin.ink)
                .lineLimit(1).truncationMode(.tail)
            if isActiveClaude {
                Circle().fill(skin.ramp(.healthy)).frame(width: 5, height: 5)
                    .help("Active Claude account")
            }
            if let health, health.isNotable {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(health == .down ? skin.ramp(.critical) : skin.ramp(.warming))
                    .help(health == .down ? "Down" : "Degraded")
            }
            Spacer(minLength: 6)
            Text(reading.text)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(reading.color)
                .opacity(usage.status == .stale ? 0.55 : 1)
            if let reset = metric?.resetAt, reset > Date() {
                Text(ExhaustedReset.compact(until: reset, from: Date()))
                    .font(.caption2.monospacedDigit()).foregroundStyle(skin.faint)
                    .frame(minWidth: 26, alignment: .trailing)
            } else {
                Text("").frame(minWidth: 26)   // keep the % column aligned
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(skin.card))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(skin.edge, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { if let url = dashboard { NSWorkspace.shared.open(url) } }
        .help(dashboard != nil ? "Open \(usage.displayName)'s usage dashboard" : "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(usage.displayName): \(reading.text)\(metric?.resetAt.map { ", resets \($0.formatted(.relative(presentation: .named)))" } ?? "")")
    }
}

// MARK: - One provider

struct ProviderCard: View {
    let usage: ProviderUsage
    let skin: Skin
    var health: ServiceHealth? = nil
    var refreshing: Bool = false
    var canWebLogin: Bool = false
    var canKey: Bool = false
    /// Claude's peak-hours window is active (and the user opted in) — warm the card so it
    /// reads as "busier than usual right now," matching the menu-bar flame.
    var peak: Bool = false
    /// For a Claude account card: the switch label + whether it's the live account. nil for
    /// other cards (and before the second Claude account exists). Drives the header Active/Switch chip.
    var claudeSwitch: (label: String, isActive: Bool)? = nil
    /// This Claude account's saved token has been signed out (invalid_grant). Distinct from a
    /// generic read error: it names the fix (`claude /login` + re-save) instead of dead-ending.
    var signedOut: Bool = false
    var onLogin: () -> Void
    var onSettings: () -> Void = {}
    /// Flip the live Claude account (in-app, via `ClaudeAccounts`). Passed only for Claude cards.

    /// Stale data, or a refresh in flight over a still-shown reading: dim the meters so
    /// the number reads as "not live right now" without the card flashing to empty.
    private var dim: Bool { usage.status == .stale || (refreshing && !usage.metrics.isEmpty) }

    /// Open the provider's own usage dashboard (the source of truth this card indexes).
    private var dashboard: URL? { ProviderInfo.dashboardURL(usage.provider) }

    /// Header layout under pressure: the chips (plan, ACTIVE/Switch, health) are `fixedSize`
    /// so they can never truncate into "ACTI…"/"De-gra…" — the provider NAME is the one
    /// element that gives way (single line, tail-truncated), and the health pill drops its
    /// word before the name has to (ViewThatFits → icon-only, words in the tooltip).
    private var cardHeader: some View {
        HStack(spacing: 6) {
            ProviderBadge(id: usage.provider, skin: skin)
            Text(usage.displayName)
                .font(.subheadline.weight(.semibold)).foregroundStyle(skin.ink)
                .lineLimit(1).truncationMode(.tail)
            if let plan = usage.plan {
                Text(plan.uppercased())
                    .font(.caption2.weight(.bold)).foregroundStyle(skin.bg2)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(skin.clay, in: Capsule())
                    .fixedSize()
            }
            // Read-only: the ACTIVE chip marks the live account. There is no Switch button —
            // writing Claude Code's Keychain item evicts it from that item's partition list
            // and leaves a password prompt every ~20 minutes that we can't silently repair
            // (see ClaudeAccounts.switchTo). Change accounts with `claude /login`.
            if let cs = claudeSwitch, cs.isActive {
                Text("ACTIVE")
                    .font(.caption2.weight(.bold)).foregroundStyle(skin.ramp(.healthy))
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(skin.ramp(.healthy).opacity(0.15), in: Capsule())
                    .fixedSize()
                    .help("This is the live Claude account for the CLI")
            }
            if peak {
                Image(systemName: "flame.fill")
                    .font(.caption2).foregroundStyle(skin.ramp(.pressing))
                    .help("Peak hours · \(PeakHours.windowLabel)")
                    .accessibilityLabel("Peak hours")
            }
            Spacer(minLength: 4)
            if let health, health.isNotable {
                ServiceHealthPill(health: health, skin: skin)
            }
            if dashboard != nil {
                Image(systemName: "arrow.up.right.square")
                    .font(.caption2).foregroundStyle(skin.faint)
            }
            StatusDot(status: usage.status, skin: skin)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            cardHeader
                .contentShape(Rectangle())
                .onTapGesture { if let url = dashboard { NSWorkspace.shared.open(url) } }
                .help(dashboard != nil ? "Open \(usage.displayName)'s usage dashboard" : "")

            switch usage.status {
            case .needsLogin:
                if canWebLogin {
                    Button("Log in", action: onLogin)
                        .controlSize(.small).buttonStyle(.bordered).tint(skin.clay)
                } else if canKey {
                    Button { onSettings() } label: { Text("Add a key in Settings →").font(.caption) }
                        .buttonStyle(.borderless).tint(skin.clay)
                } else {
                    Text("No local session. Sign in with its CLI.")
                        .font(.caption).foregroundStyle(skin.faint)
                }
            case .error:
                if signedOut {
                    Text("Signed out. Run `claude /login` to this account, then re-save it in Settings.")
                        .font(.caption).foregroundStyle(skin.faint).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Couldn't read usage.").font(.caption).foregroundStyle(skin.faint)
                }
            case .ok, .stale:
                if usage.metrics.isEmpty {
                    Text("No meters reported.").font(.caption).foregroundStyle(skin.faint)
                } else {
                    ForEach(usage.metrics) { GaugeRow(metric: $0, skin: skin) }
                        .opacity(dim ? 0.5 : 1)
                    if usage.status == .stale {
                        Text("couldn't refresh · as of \(usage.lastUpdated.formatted(.relative(presentation: .named)))")
                            .font(.caption2).foregroundStyle(skin.faint)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(peak ? skin.ramp(.warming).opacity(0.07) : skin.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(peak ? skin.ramp(.pressing).opacity(0.45) : skin.edge, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 1.5, y: 1)
    }
}

/// A small service-health pill on a card when the provider's status page reports trouble —
/// so a flat meter during an outage reads as "their side is down," not "you're fine."
/// Degrades gracefully under header pressure: the worded pill when it fits, otherwise just
/// the colored triangle (the word moves to the tooltip) — never a mid-word "De-gra…".
struct ServiceHealthPill: View {
    let health: ServiceHealth
    let skin: Skin
    private var label: String { health == .down ? "Down" : "Degraded" }
    private var color: Color { health == .down ? skin.ramp(.critical) : skin.ramp(.warming) }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8))
                Text(label).font(.caption2.weight(.semibold)).fixedSize()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(color, in: Capsule())
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10)).foregroundStyle(color)
        }
        .help("\(label) — from the provider's status page")
        .accessibilityLabel("Service \(label.lowercased())")
    }
}

struct StatusDot: View {
    let status: Status
    let skin: Skin
    var color: Color {
        switch status {
        case .ok:        skin.ramp(.healthy)
        case .stale:     skin.ramp(.warming)
        case .needsLogin: skin.clay
        case .error:     skin.ramp(.critical)
        }
    }
    var body: some View { Circle().fill(color).frame(width: 7, height: 7) }
}

// MARK: - One meter

struct GaugeRow: View {
    let metric: Metric
    let skin: Skin

    var body: some View {
        if metric.unlimited {
            unlimitedRow
        } else {
            meteredRow
        }
    }

    /// An uncapped window: name it, mark it Unlimited, draw a full faint track (no fill,
    /// no percent, no reset) so it reads as "infinite headroom here" not "0% used".
    private var unlimitedRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(metric.label).font(.caption).foregroundStyle(skin.ink2)
                Spacer()
                HStack(spacing: 3) {
                    Image(systemName: "infinity").font(.caption2.weight(.bold))
                    Text("Unlimited").font(.caption.weight(.medium))
                }
                .foregroundStyle(skin.ramp(.healthy))
            }
            // A flat olive track signals "open road" without implying a level of use.
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(skin.ramp(.healthy).opacity(0.18))
                .frame(height: 8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.label): unlimited, no cap")
    }

    private var meteredRow: some View {
        let pace = metric.paceStatus()
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(metric.label).font(.caption).foregroundStyle(skin.ink2)
                Spacer()
                Text(rightLabel).font(.caption.monospacedDigit()).foregroundStyle(skin.ink2)
            }
            if let f = metric.fractionUsed {
                SegmentedGauge(fraction: f,
                               severity: metric.severityFraction ?? f,
                               skin: skin,
                               paceElapsed: pace?.elapsed)
            }
            HStack(spacing: 5) {
                if let reset = metric.resetAt {
                    Text("resets \(reset.formatted(.relative(presentation: .named)))")
                        .font(.caption2).foregroundStyle(skin.faint)
                }
                if let pace {
                    if metric.resetAt != nil {
                        Text("·").font(.caption2).foregroundStyle(skin.faint)
                    }
                    // With the reset time already on the line, the compact form ("8% in
                    // reserve") skips a second "until reset"; deficit keeps its full
                    // run-out/landing clause — that's the actionable part.
                    Text(metric.resetAt != nil ? pace.shortSummary() : pace.summary())
                        .font(.caption2.weight(pace.kind == .deficit ? .medium : .regular))
                        .foregroundStyle(paceColor(pace))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// Reserve reads calm (olive), even reads neutral, deficit warms — pressing when the
    /// projected run-out is near enough to name a clock time (same horizon the phrase uses).
    private func paceColor(_ p: PaceStatus) -> Color {
        switch p.kind {
        case .reserve: skin.ramp(.healthy)
        case .even:    skin.faint
        case .deficit:
            skin.ramp((p.runsOutAt.map { $0.timeIntervalSinceNow < PaceStatus.clockHorizon } ?? false)
                      ? .pressing : .warming)
        }
    }

    private var accessibilityText: String {
        var s = metric.label
        if let p = metric.percentUsed { s += ", \(Int(p.rounded())) percent used" }
        else if let u = metric.used, let l = metric.limit { s += ", \(Int(u)) of \(Int(l))" }
        if let reset = metric.resetAt { s += ", resets \(reset.formatted(.relative(presentation: .named)))" }
        if let pace = metric.paceStatus() { s += ", \(pace.summary())" }
        return s
    }

    private var rightLabel: String {
        if let p = metric.percentUsed { return "\(Int(p.rounded()))% used" }
        if let u = metric.used, let l = metric.limit { return "\(Int(u))/\(Int(l))" }
        return ""
    }
}

/// Twenty-segment meter on the warm ramp. Lit segments climb olive→amber→terracotta→rust
/// by their own position, so the bar shows how hot you are, not just how far. Twenty
/// segments (was ten) so the last stretch reads true — 90% used now leaves two clear
/// empty segments instead of lighting the whole bar. Over-cap (severity > 1) paints the
/// whole bar aubergine. The optional pace tick marks the even-burn line: fill to the
/// right of it = ahead of pace, on track to run out early.
struct SegmentedGauge: View {
    let fraction: Double   // 0...1, clamped — how many segments light
    let severity: Double   // unclamped — drives over-cap runaway color
    let skin: Skin
    var paceElapsed: Double? = nil  // 0...1 even-burn position for the pace tick
    var segments = 20

    var body: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 2) {
                ForEach(0..<segments, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(color(i))
                }
            }
            if let e = paceElapsed {
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(skin.ink.opacity(0.55))
                        .frame(width: 2, height: geo.size.height + 5)
                        .position(x: geo.size.width * CGFloat(min(max(e, 0), 1)),
                                  y: geo.size.height / 2)
                }
            }
        }
        .frame(height: 8)
    }

    private func color(_ i: Int) -> Color {
        let threshold = Double(i) / Double(segments)
        let lit = fraction > threshold + 0.0001
        guard lit else { return skin.edge.opacity(0.55) }
        if severity > 1.0 { return skin.ramp(.runaway) }
        return skin.ramp(Double(i + 1) / Double(segments))
    }
}

// MARK: - Login window hosting the selected collector's WKWebView

/// Resolves `model.loginTargetID` to that provider's webview and drives its login.
/// Provider-aware so a single login window serves z.ai, Claude, and future web collectors.
struct LoginHost: View {
    @Bindable var model: AppModel
    var body: some View {
        Group {
            if let id = model.loginTargetID, let webView = model.loginWebView(for: id) {
                LoginView(webView: webView)
                    .onAppear {
                        NSApp.activate(ignoringOtherApps: true)
                        model.startLogin(id)
                    }
            } else {
                Text("No provider selected.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onDisappear { Task { await model.refresh() } }
    }
}

struct LoginView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
