import Foundation
import UserNotifications
import HeadroomKit

/// Native threshold alerts. Quiet by design: off until the user opts in, and each
/// (provider, meter, threshold) fires at most once per window — we only notify when a
/// meter *crosses up* through a threshold between refreshes, and reset the memory when
/// the meter falls back (a new window). No alert storms, no repeats.
@MainActor
final class Notifier {
    /// `UNUserNotificationCenter.current()` aborts when there's no app bundle (raw SwiftPM
    /// executable in dev). Only reach for it once Headroom runs as a real .app (Phase 6).
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier != nil ? .current() : nil
    }
    private var authorized = false
    /// Highest threshold already alerted for a meter key, so we don't re-fire.
    private var firedAt: [String: Int] = [:]

    func requestAuthorizationIfNeeded() {
        center?.requestAuthorization(options: [.alert, .sound]) { [weak self] ok, _ in
            Task { @MainActor in self?.authorized = ok }
        }
    }

    /// Compare the latest readings against the configured thresholds and post for any
    /// fresh crossing. `thresholds` are percents (e.g. [75, 90, 95]).
    func evaluate(_ usages: [ProviderUsage], thresholds: [Int], enabled: Bool) {
        guard enabled else { firedAt.removeAll(); return }
        let sorted = thresholds.sorted()
        for u in usages {
            for m in u.metrics where m.authoritative {
                guard let pct = m.fractionUsed.map({ $0 * 100 }) else { continue }
                let key = "\(u.id)|\(m.label)"
                let crossed = sorted.filter { Double($0) <= pct }.max()   // highest passed
                let prior = firedAt[key]
                if let c = crossed {
                    if prior == nil || c > prior! {     // new, higher crossing
                        post(provider: u.displayName, meter: m.label, percent: Int(pct.rounded()),
                             reset: m.resetAt)
                        firedAt[key] = c
                    }
                } else {
                    firedAt[key] = nil                  // dropped below all → window reset
                }
            }
        }
    }

    private func post(provider: String, meter: String, percent: Int, reset: Date?) {
        guard authorized, let center else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(provider) — \(percent)% used"
        var body = "\(meter) is at \(percent)%."
        if let reset { body += " Resets \(reset.formatted(.relative(presentation: .named)))." }
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: "\(provider)-\(meter)-\(percent)",
                                        content: content, trigger: nil)
        center.add(req)
    }
}
