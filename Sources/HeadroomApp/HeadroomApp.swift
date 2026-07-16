import SwiftUI
import AppKit
import HeadroomKit

/// Entry point. `--snapshot <path>` renders the popover to a PNG and exits (a dev
/// affordance for visual checks); otherwise the normal menu-bar app runs.
@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        // `--snapshot` is handled in applicationDidFinishLaunching (a real NSHostingView +
        // cacheDisplay), NOT here via ImageRenderer — ImageRenderer can't rasterize SF
        // Symbols and emits the yellow "missing image" placeholder for every symbol button.
        if let i = args.firstIndex(of: "--render-icon") {
            let path = args[safe: i + 1] ?? "icon.png"
            let px = Int(args[safe: i + 2] ?? "1024") ?? 1024
            MainActor.assumeIsolated { AppIcon.render(to: path, px: px) }
            return
        }
        // Deterministic check of the composited menu-bar label (two providers + %, plus an
        // exhausted meter that must render its reset countdown instead of "100%"), so the
        // multi-hat render can be verified offscreen without watching the live menu bar.
        // Renders one row per style × used/remaining, so every glyph mode is on the sheet.
        if let i = args.firstIndex(of: "--compose-shot") {
            let path = args[safe: i + 1] ?? "menubar.png"
            MainActor.assumeIsolated {
                let items = [AppModel.GlyphItem(id: "claude", fraction: 0.02, meterLabel: "Weekly"),
                             AppModel.GlyphItem(id: "kimi", fraction: 0.14, meterLabel: nil),
                             AppModel.GlyphItem(id: "codex", fraction: 1.0, meterLabel: nil,
                                                resetAt: Date().addingTimeInterval(45 * 60))]
                var rows: [NSImage] = []
                for style in GlyphStyle.allCases {
                    for remaining in [false, true] {
                        rows.append(MenuBarGlyph.compose(items: items, showPercent: true,
                                                         style: style, flame: false,
                                                         showRemaining: remaining))
                    }
                }
                let pad: CGFloat = 8
                let w = (rows.map(\.size.width).max() ?? 1) + pad * 2
                let h = rows.reduce(0) { $0 + $1.size.height + pad } + pad
                let canvas = NSImage(size: NSSize(width: w, height: h))
                canvas.lockFocus()
                NSColor.windowBackgroundColor.setFill()
                NSRect(origin: .zero, size: canvas.size).fill()
                var y = pad
                for row in rows.reversed() {   // draw bottom-up; reversed keeps declaration order top-down
                    row.draw(at: NSPoint(x: pad, y: y), from: .zero, operation: .sourceOver, fraction: 1)
                    y += row.size.height + pad
                }
                canvas.unlockFocus()
                if let tiff = canvas.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                }
            }
            return
        }
        HeadroomApp.main()
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// Dev launch flags. `--open <windowId>` opens that window on launch; add
/// `--shoot <path>` to render that window to a PNG and quit (reliable self-capture,
/// no screen z-order fight, captures real Charts).
enum AppLaunchFlags {
    private static func value(after flag: String) -> String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: flag), i + 1 < a.count else { return nil }
        return a[i + 1]
    }
    static var openWindowID: String? { value(after: "--open") }
    static var shootPath: String? { value(after: "--shoot") }
    static var snapshotPath: String? { value(after: "--snapshot") }
}

/// Render the largest visible standard window's content to a PNG (real rendering,
/// including Swift Charts) and exit. Used for verification screenshots.
@MainActor
enum WindowShooter {
    static func shoot(to path: String) {
        let win = NSApp.windows
            .filter { $0.isVisible && $0.contentView != nil && $0.frame.height > 200 }
            .max(by: { $0.frame.height < $1.frame.height })
        guard let view = win?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            FileHandle.standardError.write(Data("shoot: no window\n".utf8)); exit(1)
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
        exit(0)
    }
}

struct HeadroomApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
                .task { model.start() }
                .onAppear { model.noteMenuOpened() }   // freshen on look + drive adaptive cadence
                .preferredColorScheme(model.prefs.appearance.scheme)
        } label: {
            // The entire label is ONE pre-composited NSImage (model.menuBarImage), rebuilt in
            // AppModel.recomputeMenuBar on every refresh and every glyph-pref change. Read it
            // in the Scene body so the Scene owns the Observation dependency. A single
            // Image(nsImage:) swap is the one label shape a MenuBarExtra renders reliably — a
            // ForEach of multiple hats + Text updated the first item but dropped a 2nd
            // provider's hat (structural growth not reflected). Compositing avoids that.
            Image(nsImage: model.menuBarImage)
                .accessibilityLabel(model.menuBarA11y)
        }
        .menuBarExtraStyle(.window)

        Window("Log in", id: "login") {
            LoginHost(model: model)
                .frame(minWidth: 520, minHeight: 640)
                .preferredColorScheme(model.prefs.appearance.scheme)
        }
        .defaultSize(width: 560, height: 720)

        Window("Usage History", id: "history") {
            HistoryView(model: model)
                .frame(minWidth: 560, minHeight: 440)
                .preferredColorScheme(model.prefs.appearance.scheme)
        }
        .defaultSize(width: 780, height: 600)
        .windowResizability(.contentMinSize)

        // A regular Window, not the `Settings` scene: the `Settings` scene won't surface
        // from an `.accessory` MenuBarExtra app (showSettingsWindow: returns true but opens
        // nothing — verified), so we open this with openWindow like the other windows.
        // `.contentMinSize` (not `.contentSize`) so the user can resize it freely; the view
        // sets only a minimum, no fixed lock.
        Window("Settings", id: "settings") {
            SettingsView(model: model)
                .preferredColorScheme(model.prefs.appearance.scheme)
        }
        .defaultSize(width: 460, height: 520)
        .windowResizability(.contentMinSize)
    }
}

/// Builders for the menu-bar glyph: the shared chef-hat as a fill gauge that warms
/// olive→rust as the tightest meter climbs, with the % beside it. One hat, two tools.
///
/// The whole label is composited into a SINGLE `NSImage` (flame + each provider's hat +
/// its %) and handed to the `MenuBarExtra` label as one `Image(nsImage:)`. That is the
/// only label shape a MenuBarExtra renders reliably: a `ForEach` of multiple hats + `Text`
/// updated the first item but silently dropped a 2nd provider's hat (structural growth not
/// reflected), and GeometryReader/.mask render to nothing inline. An image always renders.
enum MenuBarGlyph {
    /// Compose the full menu-bar label into one image, laid out left→right like the old
    /// HStack: optional flame, then per item a hat (+ % when shown). 7pt between items,
    /// 3pt between a hat and its %. `showRemaining` flips the % text and the hat/bar fill
    /// to "what's left" (the battery already draws remaining; tier colors stay usage-keyed).
    @MainActor static func compose(items: [AppModel.GlyphItem], showPercent: Bool,
                                   style: GlyphStyle, flame: Bool,
                                   resetWhenExhausted: Bool = true,
                                   showRemaining: Bool = false) -> NSImage {
        let h: CGFloat = 18, interItem: CGFloat = 7, innerGap: CGFloat = 3
        var pieces: [(img: NSImage, gap: CGFloat)] = []
        if flame, let f = flameImage() { pieces.append((f, 0)) }
        for item in items {
            let gap: CGFloat = pieces.isEmpty ? 0 : interItem
            pieces.append((glyphImage(for: item.fraction, style: style,
                                      letter: letter(for: item.id), showRemaining: showRemaining), gap))
            if showPercent, let frac = item.fraction {
                // An exhausted meter's "100%" is dead information — show when it's back
                // instead ("45m", "3h"), in the same tier color, then revert after reset.
                let clamped = min(max(frac, 0), 1)
                let percent = Int(((showRemaining ? 1 - clamped : clamped) * 100).rounded())
                let text = (resetWhenExhausted
                            ? ExhaustedReset.countdown(fraction: frac, resetAt: item.resetAt)
                            : nil) ?? "\(percent)%"
                pieces.append((textImage(text, color: NSColor(tint(for: frac))), innerGap))
            }
        }
        let totalW = pieces.reduce(0) { $0 + $1.gap + $1.img.size.width }
        let canvas = NSImage(size: NSSize(width: max(1, totalW), height: h))
        canvas.lockFocus()
        var x: CGFloat = 0
        for p in pieces {
            x += p.gap
            let y = ((h - p.img.size.height) / 2).rounded()
            p.img.draw(at: NSPoint(x: x.rounded(), y: y), from: .zero, operation: .sourceOver, fraction: 1)
            x += p.img.size.width
        }
        canvas.unlockFocus()
        canvas.isTemplate = false   // keep the warm tier colors, don't monochrome it
        return canvas
    }

    /// VoiceOver label for the composed image: every item read out in order.
    @MainActor static func a11y(items: [AppModel.GlyphItem], showRemaining: Bool = false) -> String {
        guard !items.isEmpty else { return "Headroom usage" }
        let parts = items.map { item -> String in
            let base = item.id == "_tightest" ? "tightest meter" : Prefs.displayName(item.id)
            let who = item.meterLabel.map { "\(base) \($0)" } ?? base
            guard let f = item.fraction else { return "\(who) no data" }
            if let back = ExhaustedReset.countdown(fraction: f, resetAt: item.resetAt) {
                return "\(who) exhausted, resets in \(back)"
            }
            let clamped = min(max(f, 0), 1)
            return showRemaining
                ? "\(who) \(Int(((1 - clamped) * 100).rounded())) percent left"
                : "\(who) \(Int((f * 100).rounded())) percent used"
        }
        return "Headroom: " + parts.joined(separator: ", ")
    }

    /// The monogram letter for a glyph item: the provider's badge letter, or "H"(eadroom)
    /// for the aggregate tightest item, which belongs to no single provider.
    @MainActor private static func letter(for id: String) -> String {
        id == "_tightest" ? "H" : ProviderInfo.letter(id)
    }

    private static func flameImage() -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            .applying(.init(paletteColors: [NSColor(Color(hex: Theme.light.pressing))]))
        return NSImage(systemSymbolName: "flame.fill", accessibilityDescription: "Claude peak hours")?
            .withSymbolConfiguration(cfg)
    }

    private static func textImage(_ s: String, color: NSColor) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let str = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        let size = str.size()
        let img = NSImage(size: NSSize(width: ceil(size.width), height: ceil(size.height)))
        img.lockFocus()
        str.draw(at: .zero)
        img.unlockFocus()
        return img
    }

    // Menu-bar items resolve their own light/dark; the warm ramp reads on both.
    private static func tint(for fraction: Double?) -> Color {
        guard let f = fraction else { return .secondary }
        return Color(hex: Theme.light.ramp(fraction: f))
    }

    @MainActor private static func glyphImage(for fraction: Double?, style: GlyphStyle,
                                              letter: String = "H",
                                              showRemaining: Bool = false) -> NSImage {
        let f = fraction ?? 0
        let c = tint(for: fraction)
        // Remaining mode inverts the hat/bar fill (they drain as you spend). The battery
        // already draws charge-left; the monogram has no fill. Tint stays usage-keyed.
        let fill = showRemaining ? 1 - min(max(f, 0), 1) : f
        let content: AnyView = switch style {
        case .hat:      AnyView(ChefHatGauge(fraction: fill, tint: c).frame(width: 16, height: 16))
        case .bar:      AnyView(BarGauge(fraction: fill, tint: c))
        case .battery:  AnyView(BatteryGauge(fraction: f, tint: c))
        case .monogram: AnyView(MonogramGauge(letter: letter, tint: c))
        }
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let img = renderer.nsImage else { return NSImage() }
        img.isTemplate = false   // keep the warm tier color, don't monochrome it
        return img
    }
}

/// Agent app: no dock icon, lives in the menu bar. In `--shoot` mode we render the
/// requested view in a plain NSWindow and capture it (reliable, real Charts) — the
/// `.window`-style MenuBarExtra doesn't render until clicked, so we can't rely on it.
///
/// Note: `--shoot settings` logs ~68 benign "AttributeGraph: cycle detected" lines and
/// still captures a correct PNG. That cycle is an artifact of hosting a control-heavy
/// view (Buttons/SecureField/SF-Symbol Labels) in a bare `NSHostingView` here; it does
/// NOT occur in the shipped app, which presents Settings as a normal Window scene opened
/// via openWindow (verified 0 cycles in normal launch). History shoots clean because it
/// has no interactive controls. Don't re-bisect — it's harness-only.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var shotWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let snap = AppLaunchFlags.snapshotPath {
            NSApp.setActivationPolicy(.regular)
            renderPopover(to: snap)
            return
        }
        if let shot = AppLaunchFlags.shootPath {
            NSApp.setActivationPolicy(.regular)
            renderAndShoot(AppLaunchFlags.openWindowID ?? "history", to: shot)
            return
        }
        // Single-instance: if another Headroom is already running, hand off to it and quit
        // so we never stack two menu-bar hats.
        if let bid = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
                .filter { $0.processIdentifier != NSRunningApplication.current.processIdentifier }
            if let existing = others.first {
                existing.activate()
                NSApp.terminate(nil)
                return
            }
        }
        NSApp.setActivationPolicy(.accessory)
        if !Prefs.shared.hasOnboarded { showOnboarding() }
    }

    /// First-run welcome, shown once. Marked onboarded the moment it's shown (so it never
    /// reappears even if dismissed via the close button). An accessory app isn't frontmost,
    /// so activate + key-and-front to surface it. Built as a plain NSWindow (deterministic
    /// from here; the menu-bar label renders too lazily to drive an openWindow on launch).
    @MainActor private func showOnboarding() {
        Prefs.shared.hasOnboarded = true
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Welcome to Headroom"
        win.isReleasedWhenClosed = false
        win.center()
        let view = OnboardingView(prefs: .shared) { [weak self] in
            self?.onboardingWindow?.close()
            self?.onboardingWindow = nil
        }
        win.contentView = NSHostingView(rootView: view)
        onboardingWindow = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    /// Render the popover (light + dark, side by side) to a PNG via a real NSHostingView +
    /// cacheDisplay, then quit. The real-view path resolves SF Symbols (the refresh / history
    /// / gear buttons), which ImageRenderer cannot — it would draw the missing-image
    /// placeholder for each. Mock data so it shows the full 5-provider lineup + capacity + hint.
    @MainActor private func renderPopover(to path: String) {
        func mock() -> AppModel {
            let m = AppModel(); m.usages = Snapshot.mock; m.lastRefresh = Date()
            // Exercise the crammed-header case: health pills competing with plan/ACTIVE
            // chips (the pill must shed its word before anything truncates mid-word).
            m.serviceHealth = ["claude": .degraded, "codex": .down]
            return m
        }
        // Deliberate split: light panel = full cards, dark panel = Overview (compact) mode,
        // so every snapshot exercises both popover modes (forceCompact keeps the harness
        // from writing the user's real popoverCompact pref).
        let root = HStack(alignment: .top, spacing: 16) {
            MenuContent(model: mock(), forceCompact: false).environment(\.colorScheme, .light)
            MenuContent(model: mock(), forceCompact: true).environment(\.colorScheme, .dark)
        }
        .padding(16)
        .background(Color(white: 0.5))

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 1000),
                           styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: root)
        win.contentView = host
        win.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        win.setContentSize(host.fittingSize)   // shrink-wrap to the rendered content
        shotWindow = win
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            guard let view = win.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
            }
            exit(0)
        }
    }

    @MainActor private func renderAndShoot(_ id: String, to path: String) {
        let model = AppModel()
        model.warmSpend()   // the History Spend panel reads the warm cache; a cached scan lands well inside the capture delay
        let scheme: ColorScheme = .light
        // Synthetic burn samples so the burn-down chart shoots deterministically (the real
        // store only accrues while the app runs): a session that idles, then burns hard
        // past the even-burn line — both sides of the guide visible.
        let t0 = Date().addingTimeInterval(-4 * 3600)
        let burn: [BurnLane: [BurnSample]] = [
            .session: [(0.0, 0.02), (0.5, 0.06), (1.0, 0.08), (1.5, 0.08), (2.0, 0.22),
                       (2.5, 0.41), (3.0, 0.58), (3.5, 0.72), (3.9, 0.86)]
                .map { BurnSample(t: t0.addingTimeInterval($0.0 * 3600), f: $0.1) },
            .week: [(0.0, 0.10), (12.0, 0.14), (24.0, 0.21), (48.0, 0.33), (72.0, 0.35),
                    (96.0, 0.52)].map { BurnSample(t: t0.addingTimeInterval(-96 * 3600 + $0.0 * 3600), f: $0.1) },
        ]
        // Tall enough that History's full panel stack (trend, heatmap, burn-down, spend,
        // utilization) is on the sheet — a 560pt viewport clipped everything below the heatmap.
        let h: CGFloat = id == "settings" ? 560 : 1700
        let root: AnyView = id == "settings"
            ? AnyView(SettingsView(model: model).environment(\.colorScheme, scheme))
            : AnyView(HistoryView(model: model, preloaded: Snapshot.mockTokens, preloadedBurn: burn)
                .frame(width: 720, height: h).environment(\.colorScheme, scheme))
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: h),
                           styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = NSHostingView(rootView: root)
        win.makeKeyAndOrderFront(nil)
        shotWindow = win
        // Let the async log read + Charts settle, then capture and quit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
            guard let view = win.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
            }
            exit(0)
        }
    }
}
