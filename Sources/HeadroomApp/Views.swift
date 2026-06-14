import SwiftUI
import WebKit
import HeadroomKit

// MARK: - Menu bar dropdown

struct MenuContent: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let skin = Skin(scheme)
        VStack(alignment: .leading, spacing: 11) {
            // Dev: `--open <id>` opens that window on launch (for screenshots).
            Color.clear.frame(height: 0).task {
                if let id = AppLaunchFlags.openWindowID {
                    NSApp.activate(ignoringOtherApps: true)
                    if id == "settings" {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    } else {
                        openWindow(id: id)
                    }
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

            if model.usages.isEmpty {
                Text("No data yet.").foregroundStyle(skin.faint).font(.callout)
            }

            ForEach(model.usages) { usage in
                ProviderCard(usage: usage, skin: skin,
                             refreshing: model.isRefreshing,
                             canWebLogin: model.loginWebView(for: usage.provider) != nil,
                             canKey: model.keyService(for: usage.provider) != nil) {
                    model.loginTargetID = usage.provider
                    openWindow(id: "login")
                }
            }

            Rectangle().fill(skin.edge).frame(height: 1)
            HStack(spacing: 10) {
                if let t = model.lastRefresh {
                    Text("Updated \(t.formatted(.relative(presentation: .named)))")
                        .font(.caption2).foregroundStyle(skin.faint)
                }
                Spacer()
                Button { openWindow(id: "history") } label: { Image(systemName: "chart.bar.xaxis") }
                    .buttonStyle(.borderless).tint(skin.ink2).help("Usage history")
                SettingsLink { Image(systemName: "gearshape") }
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

// MARK: - One provider

struct ProviderCard: View {
    let usage: ProviderUsage
    let skin: Skin
    var refreshing: Bool = false
    var canWebLogin: Bool = false
    var canKey: Bool = false
    var onLogin: () -> Void

    /// Stale data, or a refresh in flight over a still-shown reading: dim the meters so
    /// the number reads as "not live right now" without the card flashing to empty.
    private var dim: Bool { usage.status == .stale || (refreshing && !usage.metrics.isEmpty) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(usage.displayName)
                    .font(.subheadline.weight(.semibold)).foregroundStyle(skin.ink)
                if let plan = usage.plan {
                    Text(plan.uppercased())
                        .font(.caption2.weight(.bold)).foregroundStyle(skin.bg2)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(skin.clay, in: Capsule())
                }
                Spacer()
                StatusDot(status: usage.status, skin: skin)
            }

            switch usage.status {
            case .needsLogin:
                if canWebLogin {
                    Button("Log in", action: onLogin)
                        .controlSize(.small).buttonStyle(.bordered).tint(skin.clay)
                } else if canKey {
                    SettingsLink { Text("Add a key in Settings →").font(.caption) }
                        .buttonStyle(.borderless).tint(skin.clay)
                } else {
                    Text("No local session — sign in with its CLI.")
                        .font(.caption).foregroundStyle(skin.faint)
                }
            case .error:
                Text("Couldn't read usage.").font(.caption).foregroundStyle(skin.faint)
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
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(skin.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(skin.edge, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 1.5, y: 1)
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
        let pace = metric.pace()
        let ahead = metric.aheadOfPace()
        VStack(alignment: .leading, spacing: 3) {
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
                if ahead {
                    if metric.resetAt != nil {
                        Text("·").font(.caption2).foregroundStyle(skin.faint)
                    }
                    Text("ahead of pace")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(skin.ramp(pace?.willExhaust == true ? .pressing : .warming))
                }
            }
        }
    }

    private var rightLabel: String {
        if let p = metric.percentUsed { return "\(Int(p.rounded()))% used" }
        if let u = metric.used, let l = metric.limit { return "\(Int(u))/\(Int(l))" }
        return ""
    }
}

/// Ten-segment meter on the warm ramp. Lit segments climb olive→amber→terracotta→rust
/// by their own position, so the bar shows how hot you are, not just how far. Over-cap
/// (severity > 1) paints the whole bar aubergine. The optional pace tick marks the
/// even-burn line: fill to the right of it = ahead of pace, on track to run out early.
struct SegmentedGauge: View {
    let fraction: Double   // 0...1, clamped — how many segments light
    let severity: Double   // unclamped — drives over-cap runaway color
    let skin: Skin
    var paceElapsed: Double? = nil  // 0...1 even-burn position for the pace tick
    var segments = 10

    var body: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 3) {
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
