import Foundation
import ServiceManagement

/// Launch-at-login via `SMAppService.mainApp`. Only works for a real signed/bundled
/// `.app` (Phase 6) — from the raw SwiftPM executable, register throws, so we report
/// `available == false` and the Settings toggle disables itself with a note.
enum LoginItem {
    static var available: Bool {
        // A bundled app has a bundleIdentifier; the bare executable does not.
        Bundle.main.bundleIdentifier != nil
    }

    static var isEnabled: Bool {
        guard available else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// Returns true on success. No-op + false when unavailable or on error.
    @discardableResult
    static func set(_ on: Bool) -> Bool {
        guard available else { return false }
        do {
            if on { try SMAppService.mainApp.register() }
            else  { try SMAppService.mainApp.unregister() }
            return true
        } catch {
            return false
        }
    }
}
