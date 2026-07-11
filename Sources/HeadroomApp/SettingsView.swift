import SwiftUI
import HeadroomKit

/// Public links. One place to change the repo slug before/after the public push.
enum HeadroomLinks {
    static let repo = URL(string: "https://github.com/BioInfo/headroom")!
    static let family = URL(string: "https://github.com/BioInfo/claudelicious")!
    /// "Request a provider" → a prefilled GitHub issue (the community channel for new tools).
    static let requestProvider = URL(string: "https://github.com/BioInfo/headroom/issues/new?template=provider-request.yml")!
    /// Contribute / report → the repo's issues.
    static let contribute = URL(string: "https://github.com/BioInfo/headroom/issues")!
    /// GitHub Sponsors (valid once Sponsors is enabled on the account).
    static let sponsor = URL(string: "https://github.com/sponsors/BioInfo")!
    static let buyMeACoffee = URL(string: "https://buymeacoffee.com/JustinHJohnson")!
}

/// Headroom preferences — Providers, Appearance, General, About. Reads/writes `Prefs`
/// and drives `AppModel` (key paste, login, refresh). Styled in the cookbook palette.
struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openWindow) private var openWindow

    @State private var tab: Tab = .providers

    enum Tab: String, CaseIterable, Identifiable {
        case providers, appearance, general, updates, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .providers: "Providers"
            case .appearance: "Appearance"
            case .general: "General"
            case .updates: "Updates"
            case .about: "About"
            }
        }
        var icon: String {
            switch self {
            case .providers: "square.stack.3d.up"
            case .appearance: "paintpalette"
            case .general: "gearshape"
            case .updates: "arrow.down.circle"
            case .about: "info.circle"
            }
        }
    }

    var body: some View {
        let skin = Skin(model.prefs.effectiveScheme(scheme))
        VStack(spacing: 0) {
            // Custom segmented header: always-visible icon+label tabs. A plain Window's
            // TabView collapses into a "Navigation Tab Bar" overflow popup on recent macOS,
            // so we draw our own in the cookbook palette and switch content ourselves.
            HStack(spacing: 6) {
                ForEach(Tab.allCases) { t in
                    let on = tab == t
                    Button { tab = t } label: {
                        VStack(spacing: 4) {
                            Image(systemName: t.icon).font(.system(size: 15))
                            Text(t.title).font(.caption.weight(on ? .semibold : .regular))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .foregroundStyle(on ? skin.ink : skin.ink2)
                        .background(on ? skin.card : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(on ? skin.edge : Color.clear, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(skin.bg2)

            Rectangle().fill(skin.edge).frame(height: 1)

            // Each tab view manages its own scroll/form.
            Group {
                switch tab {
                case .providers:  ProvidersTab(model: model, skin: skin, openLogin: openLogin)
                case .appearance: AppearanceTab(model: model, skin: skin)
                case .general:    GeneralTab(model: model, prefs: model.prefs, skin: skin)
                case .updates:    UpdatesTab(updater: model.updater, prefs: model.prefs, skin: skin)
                case .about:      AboutTab(skin: skin)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 440, minHeight: 460)
        .background(skin.bg)
    }

    private func openLogin(_ id: String) {
        model.loginTargetID = id
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "login")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.title == "Log in" }?.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - Providers

private struct ProvidersTab: View {
    @Bindable var model: AppModel
    let skin: Skin
    var openLogin: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Track only what you pay for. Web/key providers light up once a key is pasted or you log in once.")
                    .font(.caption).foregroundStyle(skin.faint)
                ForEach(Prefs.allProviderIDs, id: \.self) { id in
                    ProviderRow(model: model, skin: skin, id: id, openLogin: openLogin)
                }
                HStack(spacing: 5) {
                    Text("Pay for a tool that isn't here?").font(.caption).foregroundStyle(skin.faint)
                    Link("Request a provider →", destination: HeadroomLinks.requestProvider)
                        .font(.caption).tint(skin.clay)
                }
                .padding(.top, 2)
            }
            .padding(16)
        }
    }
}

private struct ProviderRow: View {
    @Bindable var model: AppModel
    let skin: Skin
    let id: String
    var openLogin: (String) -> Void
    @State private var keyText = ""

    private var enabled: Binding<Bool> {
        Binding(get: { model.prefs.isEnabled(id) }, set: { model.setEnabled(id, $0) })
    }

    var body: some View {
        let kind = Prefs.kind(id)
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Toggle(isOn: enabled) {
                    Text(Prefs.displayName(id)).font(.subheadline.weight(.semibold)).foregroundStyle(skin.ink)
                }
                .toggleStyle(.switch).tint(skin.ramp(.healthy))
                Spacer()
                Text(kindLabel(kind)).font(.caption2).foregroundStyle(skin.faint)
            }

            switch kind {
            case .local:
                Text("Uses your local CLI session. No setup.").font(.caption).foregroundStyle(skin.faint)
            case .key, .web:
                if model.hasStoredKey(for: id) {
                    HStack(spacing: 8) {
                        Label("Key saved", systemImage: "checkmark.seal.fill")
                            .font(.caption).foregroundStyle(skin.ramp(.healthy))
                        Button("Clear") { model.clearKey(for: id); keyText = "" }
                            .controlSize(.small).buttonStyle(.borderless).tint(skin.ink2)
                    }
                } else {
                    HStack(spacing: 6) {
                        SecureField(Prefs.pastePlaceholder(id), text: $keyText)
                            .textFieldStyle(.roundedBorder).font(.caption)
                        Button("Save") { model.saveKey(keyText, for: id) }
                            .controlSize(.small).buttonStyle(.bordered).tint(skin.clay)
                            .disabled(keyText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if let note = Prefs.setupNote(id) {
                        Text(note).font(.caption2).foregroundStyle(skin.faint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if kind == .web {
                    Button("Log in with browser…") { openLogin(id) }
                        .controlSize(.small).buttonStyle(.borderless).tint(skin.clay)
                }
            case .login:
                Text("Log in once in a browser window. No key needed.").font(.caption).foregroundStyle(skin.faint)
                Button("Log in with browser…") { openLogin(id) }
                    .controlSize(.small).buttonStyle(.borderless).tint(skin.clay)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(skin.card))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(skin.edge, lineWidth: 1))
        .opacity(enabled.wrappedValue ? 1 : 0.6)
    }

    private func kindLabel(_ k: Prefs.Kind) -> String {
        switch k {
        case .local: "local session"
        case .key:   "API key"
        case .web:   "key or login"
        case .login: "browser login"
        }
    }
}

// MARK: - Appearance

private struct AppearanceTab: View {
    @Bindable var model: AppModel
    let skin: Skin
    private var prefs: Prefs { model.prefs }

    private enum Mode: String, Hashable { case tightest, providers, hatOnly }

    private var mode: Mode {
        switch prefs.glyphSource {
        case .tightest:  .tightest
        case .providers: .providers
        case .hatOnly:   .hatOnly
        }
    }
    private func setMode(_ m: Mode) {
        switch m {
        case .tightest: model.setGlyphSource(.tightest)
        case .hatOnly:  model.setGlyphSource(.hatOnly)
        case .providers:
            let cur = chosenProviders
            let seed = cur.isEmpty ? Array(Prefs.allProviderIDs.filter { prefs.isEnabled($0) }.prefix(1)) : cur
            model.setGlyphSource(seed.isEmpty ? .tightest : .providers(seed))
        }
    }
    private var chosenProviders: [String] {
        if case .providers(let ids) = prefs.glyphSource { return ids }
        return []
    }
    private func toggleProvider(_ id: String) {
        var ids = chosenProviders
        if let i = ids.firstIndex(of: id) { ids.remove(at: i) }
        else if ids.count < GlyphSource.maxProviders { ids.append(id) }
        model.setGlyphSource(ids.isEmpty ? .tightest : .providers(ids))
    }

    /// Which meter a chosen provider shows in the menu bar: nil = tightest, else a label.
    private func pinBinding(_ id: String) -> Binding<String?> {
        Binding(get: { prefs.pinnedMeters[id] },
                set: { model.setPinnedMeter(id, label: $0) })
    }

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: Binding(
                    get: { prefs.appearance }, set: { prefs.appearance = $0 })) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Pin the popover and windows to Light or Dark, or follow the system. The menu-bar glyph looks the same either way.")
                    .font(.caption).foregroundStyle(skin.faint)
            }
            Section {
                Picker("Menu-bar shows", selection: Binding(get: { mode }, set: { setMode($0) })) {
                    Text("Tightest meter (all providers)").tag(Mode.tightest)
                    Text("Specific providers (up to \(GlyphSource.maxProviders))").tag(Mode.providers)
                    Text("Hat only (no %)").tag(Mode.hatOnly)
                }
                if mode == .providers {
                    let chosen = chosenProviders
                    ForEach(Prefs.allProviderIDs.filter { prefs.isEnabled($0) }, id: \.self) { id in
                        Toggle(Prefs.displayName(id), isOn: Binding(
                            get: { chosen.contains(id) },
                            set: { _ in toggleProvider(id) }))
                        .toggleStyle(.checkbox)
                        .disabled(!chosen.contains(id) && chosen.count >= GlyphSource.maxProviders)
                        // When a provider with more than one meter is picked, let the user
                        // pin which % shows (e.g. Claude → Weekly), not just the tightest.
                        if chosen.contains(id) {
                            let meters = model.pinnableMeters(forProvider: id)
                            if meters.count > 1 {
                                Picker("Meter", selection: pinBinding(id)) {
                                    Text("Tightest").tag(String?.none)
                                    ForEach(meters) { Text($0.label).tag(Optional($0.label)) }
                                }
                                .padding(.leading, 18)
                            }
                        }
                    }
                    Text("Each shows its own hat + % in the menu bar, in this order. Pick which meter a multi-meter provider shows, or leave it on its tightest. Enable a provider in the Providers tab to choose it here.")
                        .font(.caption).foregroundStyle(skin.faint)
                } else {
                    Text("The glyph fills and warms with whichever meter you pick.")
                        .font(.caption).foregroundStyle(skin.faint)
                }
            }
            Section {
                Picker("Glyph style", selection: Binding(
                    get: { prefs.glyphStyle }, set: { model.setGlyphStyle($0) })) {
                    ForEach(GlyphStyle.allCases) { Text($0.title).tag($0) }
                }
                Text("The chef-hat is the family mark. Bar is a flat meter; Battery drains as you spend (reads as charge left).")
                    .font(.caption).foregroundStyle(skin.faint)
            }
            Section {
                Toggle("Show Claude “Extra usage” row", isOn: Binding(
                    get: { prefs.showClaudeExtraUsage },
                    set: { prefs.showClaudeExtraUsage = $0 }))
                Text("Off by default. It's a pay-as-you-go $ pool, not subscription headroom, so it never drives the menu-bar glyph.")
                    .font(.caption).foregroundStyle(skin.faint)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(skin.bg)
    }
}

// MARK: - General

private struct GeneralTab: View {
    let model: AppModel
    @Bindable var prefs: Prefs
    let skin: Skin
    @State private var launchAtLogin = LoginItem.isEnabled

    /// The live adaptive cadence line, e.g. "Checking every 2 min · you just looked".
    private var adaptiveCaption: String {
        guard let d = model.adaptiveDecision else { return "Checks faster while you're looking, slower when idle." }
        return "Checking every \(d.minutes) min · \(d.reason.caption)."
    }

    var body: some View {
        Form {
            Section {
                Toggle("Adaptive refresh", isOn: $prefs.adaptiveRefresh)
                    .onChange(of: prefs.adaptiveRefresh) { _, _ in _ = model.nextBaseInterval() }
                if prefs.adaptiveRefresh {
                    Text(adaptiveCaption)
                        .font(.caption).foregroundStyle(skin.faint).padding(.leading, 18)
                } else {
                    HStack {
                        Text("Refresh every")
                        Slider(value: Binding(get: { Double(prefs.refreshMinutes) },
                                              set: { prefs.refreshMinutes = Int($0) }),
                               in: 1...60, step: 1)
                        Text("\(prefs.refreshMinutes) min").monospacedDigit().foregroundStyle(skin.ink2)
                            .frame(width: 56, alignment: .trailing)
                    }
                }
                Toggle("Refresh on wake from sleep", isOn: $prefs.refreshOnWake)
                if prefs.adaptiveRefresh {
                    Text("Polls every 2–30 min based on how recently you opened Headroom, and backs off on Low Power Mode or high heat. Ignores the fixed interval.")
                        .font(.caption).foregroundStyle(skin.faint)
                }
            }
            Section {
                Toggle("Check provider status pages", isOn: $prefs.checkProviderStatus)
                Text("Shows a “Down/Degraded” badge from Anthropic & OpenAI's public status pages, so a flat meter during an outage reads as their problem, not yours. Read-only, no data sent.")
                    .font(.caption).foregroundStyle(skin.faint)
            }
            Section {
                Toggle("Show peak hours indicator", isOn: $prefs.showPeakHours)
                if prefs.showPeakHours {
                    Toggle("Show flame in menu bar", isOn: $prefs.peakHoursFlame)
                        .padding(.leading, 18)
                }
                Text("Warms the Claude card (and adds a flame) during its busy window — \(PeakHours.windowLabel). The window is an inferred heuristic, not a published Anthropic cap, so it's off by default.")
                    .font(.caption).foregroundStyle(skin.faint)
            }
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, want in
                        _ = LoginItem.set(want)
                        let actual = LoginItem.isEnabled
                        if actual != want { launchAtLogin = actual }   // reflect reality, no cycle
                    }
                .disabled(!LoginItem.available)
                if !LoginItem.available {
                    Text("Available once Headroom runs as an installed .app (Phase 6).")
                        .font(.caption).foregroundStyle(skin.faint)
                }
            }
            Section {
                Toggle("Threshold notifications", isOn: $prefs.notify)
                if prefs.notify {
                    HStack(spacing: 14) {
                        ForEach([75, 90, 95], id: \.self) { t in
                            Toggle("\(t)%", isOn: Binding(
                                get: { prefs.notifyThresholds.contains(t) },
                                set: { on in
                                    var s = Set(prefs.notifyThresholds)
                                    if on { s.insert(t) } else { s.remove(t) }
                                    prefs.notifyThresholds = s.sorted()
                                }))
                            .toggleStyle(.checkbox)
                        }
                    }
                    Toggle("Play a sound", isOn: $prefs.notifySound)
                    Toggle("Alert when a window is exhausted (and when it's back)", isOn: $prefs.notifyOnDeplete)
                    Toggle("Ping when a window refills", isOn: $prefs.notifyOnReset)
                    if prefs.isSnoozed, let until = prefs.snoozeUntil {
                        HStack {
                            Text("Snoozed until \(until.formatted(date: .omitted, time: .shortened))")
                                .foregroundStyle(skin.ink2)
                            Spacer()
                            Button("Resume") { prefs.snoozeUntil = nil }
                        }
                    } else {
                        Menu("Snooze notifications") {
                            Button("For 1 hour")  { prefs.snoozeUntil = Date().addingTimeInterval(3600) }
                            Button("For 4 hours") { prefs.snoozeUntil = Date().addingTimeInterval(4 * 3600) }
                        }
                        .fixedSize()
                    }
                    Text("Alerts when a meter crosses a level, naming the window. Quiet: one per crossing. “Exhausted” fires at the cap whatever the levels — the alert that means you're locked out.")
                        .font(.caption).foregroundStyle(skin.faint)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(skin.bg)
    }
}

// MARK: - Updates (Software Updates — built now, real engine wired once signed)

private struct UpdatesTab: View {
    @Bindable var updater: Updater
    @Bindable var prefs: Prefs
    let skin: Skin

    private func infoRow(_ label: String, _ value: String, _ icon: String) -> some View {
        HStack {
            Label(label, systemImage: icon).foregroundStyle(skin.ink2)
            Spacer()
            Text(value).foregroundStyle(skin.ink).monospacedDigit()
        }
    }

    var body: some View {
        Form {
            Section("Version") {
                infoRow("Current version", AppInfo.versionLabel, "shippingbox")
                infoRow("Last checked",
                        updater.lastChecked.map { $0.formatted(.relative(presentation: .named)) } ?? "Never",
                        "clock")
            }
            Section {
                Toggle("Automatic updates", isOn: $prefs.autoUpdate)
                    .onChange(of: prefs.autoUpdate) { _, on in updater.automaticallyChecksForUpdates = on }
                Text(updater.isLive
                     ? "Check for and download updates in the background. Updates are EdDSA-signed and verified before they install."
                     : "Auto-update runs in the installed, signed app. This dev build updates by pulling the repo and rebuilding.")
                    .font(.caption).foregroundStyle(skin.faint)
            }
            Section {
                Button { updater.checkForUpdates() } label: {
                    Label("Check for Updates", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large).buttonStyle(.borderedProminent).tint(skin.clay)
                if let msg = updater.statusMessage {
                    Text(msg).font(.caption).foregroundStyle(skin.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.shield.fill").foregroundStyle(skin.ramp(.healthy))
                    Text("Updates are cryptographically signed and verified before they install.")
                        .font(.caption).foregroundStyle(skin.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(skin.bg)
    }
}

// MARK: - About

private struct AboutTab: View {
    let skin: Skin

    private func point(_ icon: String, _ tint: Color, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon).font(.body).foregroundStyle(tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(skin.ink)
                Text(body).font(.caption2).foregroundStyle(skin.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                ChefHat().fill(skin.clay).frame(width: 50, height: 50)
                Text("Headroom").font(.title2.weight(.semibold)).foregroundStyle(skin.ink)
                Text("How much of every AI coding subscription you've got left, in one place.")
                    .font(.callout).foregroundStyle(skin.ink2)
                    .multilineTextAlignment(.center).frame(maxWidth: 320)

                // What you're getting — free, open, private.
                VStack(alignment: .leading, spacing: 10) {
                    point("checkmark.seal.fill", skin.ramp(.healthy), "Every feature is free",
                          "No premium tier, no paywall, no subscription.")
                    point("lock.open.fill", skin.clay, "Open source",
                          "MIT licensed. Read it, change it, send a pull request.")
                    point("hand.raised.fill", skin.ramp(.pressing), "No tracking",
                          "No analytics, no telemetry. Everything stays on your Mac.")
                }
                .padding(13).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(skin.card))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(skin.edge, lineWidth: 1))

                Text("If Headroom is useful, you can help keep it going.")
                    .font(.caption).foregroundStyle(skin.ink2)

                // The Buy Me a Coffee mark keeps its recognizable yellow on the cream ground.
                Link(destination: HeadroomLinks.buyMeACoffee) {
                    HStack(spacing: 8) {
                        Image(systemName: "cup.and.saucer.fill")
                        Text("Buy Me a Coffee").fontWeight(.semibold)
                    }
                    .foregroundStyle(Color(hex: "2A2520"))
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .background(Color(hex: "FFDD00"), in: Capsule())
                }
                .buttonStyle(.plain)

                HStack(spacing: 16) {
                    Link(destination: HeadroomLinks.sponsor) {
                        Label("Sponsor", systemImage: "heart.fill")
                    }.tint(skin.ramp(.critical))
                    Link(destination: HeadroomLinks.repo) {
                        Label("Star on GitHub", systemImage: "star.fill")
                    }.tint(skin.clay)
                    Link(destination: HeadroomLinks.contribute) {
                        Label("Contribute", systemImage: "chevron.left.forwardslash.chevron.right")
                    }.tint(skin.clay)
                }
                .font(.caption.weight(.medium))

                Link("Part of the Claudelicious family ↗", destination: HeadroomLinks.family)
                    .font(.caption).tint(skin.clay)
                Text("MIT licensed · made with the cookbook")
                    .font(.caption2).foregroundStyle(skin.faint)
            }
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        .background(skin.bg)
    }
}
