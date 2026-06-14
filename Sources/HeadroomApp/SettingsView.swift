import SwiftUI
import HeadroomKit

/// Public links. One place to change the repo slug before/after the public push.
enum HeadroomLinks {
    static let repo = URL(string: "https://github.com/BioInfo/headroom")!
    static let family = URL(string: "https://github.com/BioInfo/claudelicious")!
    /// "Request a provider" → a prefilled GitHub issue (the community channel for new tools).
    static let requestProvider = URL(string: "https://github.com/BioInfo/headroom/issues/new?template=provider-request.yml")!
}

/// Headroom preferences — Providers, Appearance, General, About. Reads/writes `Prefs`
/// and drives `AppModel` (key paste, login, refresh). Styled in the cookbook palette.
struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openWindow) private var openWindow

    @State private var tab: Tab = .providers

    enum Tab: String, CaseIterable, Identifiable {
        case providers, appearance, general, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .providers: "Providers"
            case .appearance: "Appearance"
            case .general: "General"
            case .about: "About"
            }
        }
        var icon: String {
            switch self {
            case .providers: "square.stack.3d.up"
            case .appearance: "paintpalette"
            case .general: "gearshape"
            case .about: "info.circle"
            }
        }
    }

    var body: some View {
        let skin = Skin(scheme)
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
                case .appearance: AppearanceTab(prefs: model.prefs, skin: skin)
                case .general:    GeneralTab(prefs: model.prefs, skin: skin)
                case .about:      AboutTab(skin: skin)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 460, height: 480)
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
    @Bindable var prefs: Prefs
    let skin: Skin

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
        case .tightest: prefs.glyphSource = .tightest
        case .hatOnly:  prefs.glyphSource = .hatOnly
        case .providers:
            let cur = chosenProviders
            let seed = cur.isEmpty ? Array(Prefs.allProviderIDs.filter { prefs.isEnabled($0) }.prefix(1)) : cur
            prefs.glyphSource = seed.isEmpty ? .tightest : .providers(seed)
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
        prefs.glyphSource = ids.isEmpty ? .tightest : .providers(ids)
    }

    var body: some View {
        Form {
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
                    }
                    Text("Each shows its own hat + % in the menu bar, in this order. Enable a provider in the Providers tab to pick it here.")
                        .font(.caption).foregroundStyle(skin.faint)
                } else {
                    Text("The glyph fills and warms with whichever meter you pick.")
                        .font(.caption).foregroundStyle(skin.faint)
                }
            }
            Section {
                Picker("Glyph style", selection: $prefs.glyphStyle) {
                    ForEach(GlyphStyle.allCases) { Text($0.title).tag($0) }
                }
                Text("The chef-hat is the family mark. Bar is a flat meter; Battery drains as you spend (reads as charge left).")
                    .font(.caption).foregroundStyle(skin.faint)
            }
            Section {
                Toggle("Show Claude “Extra usage” row", isOn: $prefs.showClaudeExtraUsage)
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
    @Bindable var prefs: Prefs
    let skin: Skin
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Refresh every")
                    Slider(value: Binding(get: { Double(prefs.refreshMinutes) },
                                          set: { prefs.refreshMinutes = Int($0) }),
                           in: 1...60, step: 1)
                    Text("\(prefs.refreshMinutes) min").monospacedDigit().foregroundStyle(skin.ink2)
                        .frame(width: 56, alignment: .trailing)
                }
                Toggle("Refresh on wake from sleep", isOn: $prefs.refreshOnWake)
            }
            Section {
                Toggle("Check provider status pages", isOn: $prefs.checkProviderStatus)
                Text("Shows a “Down/Degraded” badge from Anthropic & OpenAI's public status pages, so a flat meter during an outage reads as their problem, not yours. Read-only, no data sent.")
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
                    Toggle("Ping when a window refills", isOn: $prefs.notifyOnReset)
                    Text("Alerts when a meter crosses a level, naming the window. Quiet: one per crossing.")
                        .font(.caption).foregroundStyle(skin.faint)
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
    var body: some View {
        VStack(spacing: 12) {
            ChefHat().fill(skin.clay).frame(width: 54, height: 54)
            Text("Headroom").font(.title2.weight(.semibold)).foregroundStyle(skin.ink)
            Text("How much of every AI coding subscription you've got left, in one place.")
                .font(.callout).foregroundStyle(skin.ink2)
                .multilineTextAlignment(.center).frame(maxWidth: 320)
            Link("Part of the Claudelicious family ↗", destination: HeadroomLinks.family)
                .font(.callout).tint(skin.clay)
            Link("Request a provider →", destination: HeadroomLinks.requestProvider)
                .font(.caption).tint(skin.clay)
            Text("MIT licensed · made with the cookbook")
                .font(.caption2).foregroundStyle(skin.faint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background(skin.bg)
    }
}
