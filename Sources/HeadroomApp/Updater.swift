import Foundation
import Observation
import Sparkle

/// App self-update, backed by Sparkle. The Updates UI talks to this; the engine reads the
/// appcast feed configured in Info.plist (SUFeedURL + SUPublicEDKey, set by build-app.sh on
/// signed builds). Each update is EdDSA-signed by our private key and verified against the
/// embedded public key before it installs — separate from the Apple Developer ID that signs
/// the app itself. See docs/APPLE-DEVELOPER-SETUP.md.
///
/// Dormant in unbundled dev runs (`swift run`, `--snapshot`, `--shoot`): those have no
/// Info.plist, so there's no feed URL and we don't start Sparkle (which would otherwise
/// surface a "can't find the feed" error). `isLive` reflects that.
@MainActor
@Observable
final class Updater {
    /// True when Sparkle has a feed to talk to — i.e. a bundled build whose Info.plist carries
    /// SUFeedURL. False in unbundled dev runs, where we stay quiet instead of erroring.
    let isLive: Bool
    var lastChecked: Date?
    /// Short human status from the last check, shown under the button.
    var statusMessage: String?

    @ObservationIgnored private let controller: SPUStandardUpdaterController?

    init() {
        let feed = Bundle.main.infoDictionary?["SUFeedURL"] as? String
        if let feed, !feed.isEmpty {
            // startingUpdater:true reads SUFeedURL/SUPublicEDKey/SUEnableAutomaticChecks from
            // Info.plist and begins the background schedule immediately.
            controller = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
            isLive = true
        } else {
            controller = nil
            isLive = false
        }
    }

    /// Whether Sparkle checks on its own schedule. Mirrors `Prefs.autoUpdate`, which stays the
    /// source of truth; AppModel/Settings push the pref into here.
    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        lastChecked = Date()
        guard let controller else {
            statusMessage = "Auto-update runs in the installed app. This is an unsigned dev build — update by pulling the repo and rebuilding."
            return
        }
        controller.updater.checkForUpdates()
        statusMessage = "Checking for updates…"
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
