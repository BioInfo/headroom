import SwiftUI
import AppKit
import HeadroomKit

/// Entry point. `--snapshot <path>` renders the popover to a PNG and exits (a dev
/// affordance for visual checks); otherwise the normal menu-bar app runs.
@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot") {
            let path = args[safe: i + 1] ?? "headroom-snapshot.png"
            MainActor.assumeIsolated { Snapshot.run(to: path) }
            return
        }
        if let i = args.firstIndex(of: "--render-icon") {
            let path = args[safe: i + 1] ?? "icon.png"
            let px = Int(args[safe: i + 2] ?? "1024") ?? 1024
            MainActor.assumeIsolated { AppIcon.render(to: path, px: px) }
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
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Log in", id: "login") {
            LoginHost(model: model)
                .frame(minWidth: 520, minHeight: 640)
        }
        .defaultSize(width: 560, height: 720)

        Window("Usage History", id: "history") {
            HistoryView(model: model)
                .frame(minWidth: 560, minHeight: 420)
        }
        .defaultSize(width: 720, height: 480)

        Settings { SettingsView(model: model) }
    }
}

/// Menu bar glyph: the shared chef-hat as a fill gauge — it fills bottom-up and warms
/// olive→rust as the tightest meter climbs, with the % beside it. One hat, two tools.
///
/// The hat is pre-rendered to an `NSImage` because a `MenuBarExtra` label silently
/// drops anything beyond Text / SF Symbols (GeometryReader + .mask render to nothing
/// inline — that's why only the % showed). An image always renders.
struct MenuBarLabel: View {
    let model: AppModel
    var body: some View {
        // One hat+% per chosen item: a single aggregate hat for tightest/hat-only,
        // or up to three provider hats side by side for the multi-metric bar.
        HStack(spacing: 7) {
            ForEach(model.glyphItems) { item in
                HStack(spacing: 3) {
                    Image(nsImage: Self.hatImage(for: item.fraction))
                    if model.showGlyphPercent, let f = item.fraction {
                        Text("\(Int((f * 100).rounded()))%")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Self.tint(for: f))
                    }
                }
            }
        }
    }

    // Menu-bar items resolve their own light/dark; the warm ramp reads on both.
    private static func tint(for fraction: Double?) -> Color {
        guard let f = fraction else { return .secondary }
        return Color(hex: Theme.light.ramp(fraction: f))
    }

    @MainActor private static func hatImage(for fraction: Double?) -> NSImage {
        let renderer = ImageRenderer(content:
            ChefHatGauge(fraction: fraction ?? 0, tint: tint(for: fraction))
                .frame(width: 16, height: 16))
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
/// NOT occur in the shipped app, which presents Settings via the SwiftUI `Settings { }`
/// scene (verified 0 cycles in normal launch + the real settings action). History shoots
/// clean because it has no interactive controls. Don't re-bisect — it's harness-only.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var shotWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let shot = AppLaunchFlags.shootPath {
            NSApp.setActivationPolicy(.regular)
            renderAndShoot(AppLaunchFlags.openWindowID ?? "history", to: shot)
            return
        }
        NSApp.setActivationPolicy(.accessory)
    }

    @MainActor private func renderAndShoot(_ id: String, to path: String) {
        let model = AppModel()
        let scheme: ColorScheme = .light
        let root: AnyView = id == "settings"
            ? AnyView(SettingsView(model: model).environment(\.colorScheme, scheme))
            : AnyView(HistoryView(model: model, preloaded: Snapshot.mockTokens)
                .frame(width: 720, height: 560).environment(\.colorScheme, scheme))
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
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
