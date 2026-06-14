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

    var body: some View {
        let skin = Skin(scheme)
        TabView {
            ProvidersTab(model: model, skin: skin, openLogin: openLogin)
                .tabItem { Label("Providers", systemImage: "square.stack.3d.up") }
            AppearanceTab(prefs: model.prefs, skin: skin)
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            GeneralTab(prefs: model.prefs, skin: skin)
                .tabItem { Label("General", systemImage: "gearshape") }
            AboutTab(skin: skin)
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 460, height: 430)
        .background(skin.bg)
    }

    private func openLogin(_ id: String) {
        model.loginTargetID = id
        openWindow(id: "login")
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
        Binding(get: { model.prefs.isEnabled(id) }, set: { model.prefs.setEnabled(id, $0) })
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
                Text("Uses your local CLI session — no setup.").font(.caption).foregroundStyle(skin.faint)
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
                        SecureField("Paste API key", text: $keyText)
                            .textFieldStyle(.roundedBorder).font(.caption)
                        Button("Save") { model.saveKey(keyText, for: id) }
                            .controlSize(.small).buttonStyle(.bordered).tint(skin.clay)
                            .disabled(keyText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if kind == .web {
                    Button("Log in with browser…") { openLogin(id) }
                        .controlSize(.small).buttonStyle(.borderless).tint(skin.clay)
                }
            case .login:
                Text("Log in once in a browser window — no key needed.").font(.caption).foregroundStyle(skin.faint)
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
                    Text("The chef-hat fills and warms with whichever meter you pick.")
                        .font(.caption).foregroundStyle(skin.faint)
                }
            }
            Section {
                Toggle("Show Claude “Extra usage” row", isOn: $prefs.showClaudeExtraUsage)
                Text("Off by default — it's a pay-as-you-go $ pool, not subscription headroom, so it never drives the menu-bar glyph.")
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
                    Text("Alerts when a meter crosses a level, naming the window. Quiet — one per crossing.")
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
