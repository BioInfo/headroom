import Foundation
import UserNotifications
import HeadroomKit

/// Native usage alerts. Quiet by design: off until the user opts in, and each transition
/// fires at most once. The decision of *what* to alert lives in `NotificationPlan`
/// (HeadroomKit, pure + tested); this type owns only the carried state, authorization, and
/// the actual `UNUserNotification` posting.
///
/// Alert families:
/// - threshold crossings (75/90/95%) — fire once per higher crossing, reset when the window does;
/// - exhausted/restored — the window hit its cap (locked out) and later reset (threshold-independent);
/// - refilled — a crossed-but-never-exhausted window fell back below every threshold.
@MainActor
final class Notifier {
    /// `UNUserNotificationCenter.current()` aborts when there's no app bundle (raw SwiftPM
    /// executable in dev). Only reach for it once Headroom runs as a real .app (Phase 6).
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier != nil ? .current() : nil
    }
    private var authorized = false
    /// The transition memory carried between refreshes (pure value; NotificationPlan owns
    /// the rules that read/advance it).
    private var state = AlertState()

    func requestAuthorizationIfNeeded() {
        center?.requestAuthorization(options: [.alert, .sound]) { [weak self] ok, _ in
            Task { @MainActor in self?.authorized = ok }
        }
    }

    /// Compare the latest readings against the thresholds + cap and post any fresh
    /// transition. `thresholds` are percents (e.g. [75, 90, 95]). `onReset` gates the soft
    /// "window refilled" ping; `onDeplete` gates the "exhausted"/"back" pair.
    func evaluate(_ usages: [ProviderUsage], thresholds: [Int], enabled: Bool,
                  sound: Bool = true, onReset: Bool = false, onDeplete: Bool = true,
                  snoozeUntil: Date? = nil) {
        guard enabled else { state.clear(); return }
        // Advance transition state ALWAYS — even while snoozed — so resuming from a snooze
        // only surfaces *new* transitions, never a backlog of everything that fired quietly.
        let (alerts, newState) = NotificationPlan.evaluate(
            usages, thresholds: thresholds, onReset: onReset, onDeplete: onDeplete, state: state)
        state = newState
        if let until = snoozeUntil, Date() < until { return }   // snoozed: state advanced, don't post
        for alert in alerts { post(alert, sound: sound) }
    }

    private func post(_ alert: UsageAlert, sound: Bool) {
        switch alert {
        case let .crossed(provider, meter, percent, reset):
            var body = "\(meter) is at \(percent)%."
            if let reset { body += " Resets \(reset.formatted(.relative(presentation: .named)))." }
            deliver(id: "\(provider)-\(meter)-\(percent)", title: "\(provider): \(percent)% used",
                    body: body, sound: sound)
        case let .exhausted(provider, meter, reset):
            var body = "You're out of \(meter)."
            if let reset { body += " Resets \(reset.formatted(.relative(presentation: .named)))." }
            deliver(id: "\(provider)-\(meter)-exhausted", title: "\(provider): \(meter) exhausted",
                    body: body, sound: sound)
        case let .restored(provider, meter):
            deliver(id: "\(provider)-\(meter)-restored", title: "\(provider): \(meter) back",
                    body: "\(meter) reset. You've got \(provider) again.", sound: sound)
        case let .refilled(provider, meter):
            deliver(id: "\(provider)-\(meter)-refilled", title: "\(provider): back under",
                    body: "\(meter) refilled. You've got headroom again.", sound: sound)
        }
    }

    private func deliver(id: String, title: String, body: String, sound: Bool) {
        guard authorized, let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
