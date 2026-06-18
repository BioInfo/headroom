import Foundation
import Observation

/// App self-update, abstracted so the Updates UI ships now and the real engine (Sparkle)
/// drops in once the app is Developer-ID signed + an appcast feed is hosted. Until then
/// this is honest: it records the check time and says auto-update isn't wired yet, rather
/// than faking an "up to date" result. Swapping in Sparkle is a body change here, not an
/// API change for the views. See docs/APPLE-DEVELOPER-SETUP.md.
@MainActor
@Observable
final class Updater {
    /// True once a real backend (Sparkle) is wired behind a signed + notarized build.
    let isLive = false
    var lastChecked: Date?
    /// Short human status from the last check, shown under the button.
    var statusMessage: String?

    func checkForUpdates() {
        lastChecked = Date()
        statusMessage = isLive
            ? "You're on the latest version."
            : "Auto-update turns on once Headroom is signed and notarized. For now, update by pulling the repo and rebuilding."
        // When Sparkle is wired: call its updater here, guarded by `isLive`.
    }
}

/// App version, read from the bundle Info.plist (set by build-app.sh). "dev build" when run
/// unbundled via `swift run`, which has no Info.plist.
enum AppInfo {
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0" }
    static var versionLabel: String {
        version == "dev" ? "dev build" : "v\(version) (\(build))"
    }
}
