import SwiftUI
import HeadroomKit

/// First-run welcome, shown once (gated on `Prefs.hasOnboarded`). Keeps it to the two
/// decisions that matter on day one — which subscriptions you pay for, and how the menu bar
/// should look. Key paste / browser login stays in Settings (and on each card), so this
/// panel needs only `Prefs` and never blocks on a network call.
struct OnboardingView: View {
    @Bindable var prefs: Prefs
    var onDone: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let skin = Skin(scheme)
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(skin)
                    providers(skin)
                    style(skin)
                    Text("Claude and Codex work right away from your local CLI session. For MiniMax, GLM, and Kimi, paste a key in Settings (one line each). You can change any of this later.")
                        .font(.caption).foregroundStyle(skin.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(22)
            }
            Rectangle().fill(skin.edge).frame(height: 1)
            HStack {
                Spacer()
                Button("Get started") { onDone() }
                    .controlSize(.large).buttonStyle(.borderedProminent).tint(skin.clay)
            }
            .padding(16)
            .background(skin.bg2)
        }
        .frame(width: 460, height: 560)
        .background(skin.bg)
    }

    private func header(_ skin: Skin) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ChefHat().fill(skin.clay).frame(width: 34, height: 34)
                Text("Welcome to Headroom").font(.title2.weight(.semibold)).foregroundStyle(skin.ink)
            }
            Text("How much of every AI coding subscription you've got left, in one place.")
                .font(.callout).foregroundStyle(skin.ink2)
        }
    }

    private func providers(_ skin: Skin) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Which do you pay for?").font(.subheadline.weight(.semibold)).foregroundStyle(skin.ink2)
            ForEach(Prefs.allProviderIDs, id: \.self) { id in
                Toggle(isOn: Binding(get: { prefs.isEnabled(id) }, set: { prefs.setEnabled(id, $0) })) {
                    HStack(spacing: 6) {
                        Text(Prefs.displayName(id)).font(.subheadline).foregroundStyle(skin.ink)
                        Text(kindLabel(Prefs.kind(id))).font(.caption2).foregroundStyle(skin.faint)
                    }
                }
                .toggleStyle(.switch).tint(skin.ramp(.healthy))
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(skin.card))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(skin.edge, lineWidth: 1))
    }

    private func style(_ skin: Skin) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Menu-bar style").font(.subheadline.weight(.semibold)).foregroundStyle(skin.ink2)
            Picker("", selection: $prefs.glyphStyle) {
                ForEach(GlyphStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            Text("Chef hat is the family mark. Bar is a flat meter; Battery drains as you spend.")
                .font(.caption).foregroundStyle(skin.faint)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(skin.card))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(skin.edge, lineWidth: 1))
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
