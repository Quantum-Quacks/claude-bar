import AppKit
import UserNotifications

/// Posts a local notification when a usage window first crosses a threshold
/// (70% / 90% / 100%) on the way up, and once more when it resets back to zero.
/// It remembers the highest threshold already announced per window, so a window
/// parked at 72% won't re-notify on every poll — only a genuine new crossing
/// (or a reset) speaks up. Quiet by default unless the user has both granted
/// system permission and left the in-app toggle on.
@MainActor
final class Notifier {
    /// Trigger points, low to high. Crossing one upward fires a single alert.
    private let thresholds = [70, 90, 100]
    /// In-app toggle, persisted across launches; on by default.
    private let defaultsKey = "NotificationsEnabled"

    private var authorized = false
    /// Highest threshold already announced per window label (0 = none).
    private var announced: [String: Int] = [:]

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    /// Ask once at launch. Authorization is a prerequisite for posting; if the
    /// user declines, evaluate() still tracks crossings but stays silent.
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
            [weak self] granted, error in
            if let error { NSLog("Notification authorization failed: \(error)") }
            Task { @MainActor in self?.authorized = granted }
        }
    }

    /// Run after every successful fetch. Always updates the per-window state so
    /// toggling notifications on later won't replay stale crossings.
    func evaluate(usage: Usage, at now: Date) {
        check(label: "Session (5h)", window: usage.fiveHour, now: now)
        check(label: "Weekly (7d)", window: usage.sevenDay, now: now)
    }

    private func check(label: String, window: UsageWindow?, now: Date) {
        guard let window else { return }
        let pct = Int(window.effectivePercentage(at: now).rounded())
        let reached = thresholds.last(where: { $0 <= pct }) ?? 0
        let prev = announced[label] ?? 0
        guard reached != prev else { return }
        announced[label] = reached

        if reached > prev {
            post(title: "Claude \(label) at \(reached)%",
                 body: limitBody(pct: pct, window: window, now: now))
        } else if prev >= thresholds[0], reached == 0 {
            // Fell from a warned level all the way below the first threshold —
            // the window rolled over.
            post(title: "Claude \(label) reset",
                 body: "Usage is back down to \(pct)%.")
        }
    }

    private func limitBody(pct: Int, window: UsageWindow, now: Date) -> String {
        guard let resetsAt = window.resetsAt, resetsAt > now else {
            return "You're at \(pct)% of this window."
        }
        return "You're at \(pct)% · resets \(Notifier.reset(resetsAt, now: now))."
    }

    private func post(title: String, body: String) {
        guard isEnabled, authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private static func reset(_ date: Date, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = date.timeIntervalSince(now) < 23 * 3600 ? "HH:mm" : "EEE HH:mm"
        return formatter.string(from: date)
    }
}
