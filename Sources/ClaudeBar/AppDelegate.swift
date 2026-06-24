import AppKit
import ServiceManagement

/// Polls the usage endpoint on a steady run-loop timer, plus an immediate
/// refresh on launch, on wake-from-sleep, and when the menu is opened. The
/// timer fires only while the Mac is awake (user-space timers never wake a
/// sleeping Mac — they fire on the next wake), so it keeps the bars current
/// without ever disturbing sleep. Idle CPU between polls is negligible.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Poll cadence. Rate limits move over 5h/7d windows, so a few minutes is
    /// plenty; the endpoint also throttles polling faster than ~3 min.
    private let pollInterval: TimeInterval = 180
    /// Don't issue a network call more often than this, however many events fire.
    private let minFetchSpacing: TimeInterval = 45

    private let notifier = Notifier()
    private var statusItem: NSStatusItem!
    private var pollTimer: Timer?
    private var activityToken: NSObjectProtocol?
    private var usage: Usage?
    private var accountEmail: String?
    private var lastError: UsageError?
    private var lastFetchStarted: Date?
    private var isFetching = false
    private var lastDrawn: [Int?]?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        render()

        accountEmail = UsageClient.accountEmail()
        notifier.requestAuthorization()
        refresh(force: true)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil)

        // A plain run-loop timer fires reliably while the Mac is awake, unlike a
        // discretionary background activity that the OS defers on battery. It is
        // added to the main run loop, so the block runs on the main actor.
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(force: true) }
        }
        timer.tolerance = pollInterval / 6
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        // Opt out of App Nap, which would otherwise throttle the timer on a
        // background accessory app. This still allows the system to sleep
        // normally — it only keeps us from being napped while awake.
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Keep the Claude usage meter current")
    }

    @objc private func didWake() {
        accountEmail = UsageClient.accountEmail()
        refresh(force: true)
    }

    // MARK: - Fetch

    private func refresh(force: Bool, completion: (() -> Void)? = nil) {
        if isFetching { completion?(); return }
        if !force, let last = lastFetchStarted, Date().timeIntervalSince(last) < minFetchSpacing {
            completion?(); return
        }
        isFetching = true
        lastFetchStarted = Date()
        Task { [weak self] in
            let result = await UsageClient.fetch()
            guard let self else { completion?(); return }
            self.isFetching = false
            switch result {
            case .success(let usage):
                self.usage = usage
                self.lastError = nil
                self.notifier.evaluate(usage: usage, at: Date())
            case .failure(let error):
                self.lastError = error   // keep last-good usage on screen
            }
            self.render()
            completion?()
        }
    }

    // MARK: - Rendering

    private func render() {
        let now = Date()
        let fiveHour = usage?.fiveHour?.effectivePercentage(at: now)
        let sevenDay = usage?.sevenDay?.effectivePercentage(at: now)
        let rounded = [fiveHour.map { Int($0.rounded()) }, sevenDay.map { Int($0.rounded()) }]
        if rounded != lastDrawn {
            lastDrawn = rounded
            statusItem.button?.image = IconRenderer.icon(fiveHour: fiveHour, sevenDay: sevenDay)
        }
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) {
        refresh(force: false)   // exact read when you look, throttled
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let now = Date()

        if let account = accountLine() {
            menu.addItem(disabledItem(account))
            menu.addItem(.separator())
        }

        menu.addItem(infoItem(label: "Session (5h)", window: usage?.fiveHour, now: now))
        menu.addItem(infoItem(label: "Weekly (7d)", window: usage?.sevenDay, now: now))
        menu.addItem(disabledItem(statusText(now: now)))

        menu.addItem(.separator())
        let refreshItem = NSMenuItem(
            title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let notify = NSMenuItem(
            title: "Notify Near Limits", action: #selector(toggleNotifications), keyEquivalent: "")
        notify.target = self
        notify.state = notifier.isEnabled ? .on : .off
        menu.addItem(notify)

        if Bundle.main.bundleURL.pathExtension == "app" {
            let login = NSMenuItem(
                title: "Start at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
            login.target = self
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(login)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit Claude Bar",
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// "email · Max" for the signed-in account, or nil when unknown.
    private func accountLine() -> String? {
        guard let email = accountEmail else { return nil }
        if let plan = usage?.plan, !plan.isEmpty {
            return "\(email) · \(plan.capitalized)"
        }
        return email
    }

    private func statusText(now: Date) -> String {
        switch lastError {
        case .noToken:
            return "Sign in with Claude Code to enable"
        case .unauthorized:
            return "Token expired — open Claude Code once"
        case .rateLimited:
            return "Rate limited — retrying later"
        case .transport:
            return usage == nil ? "Can't reach Anthropic" : "Offline — showing last data"
        case nil:
            guard let fetchedAt = usage?.fetchedAt else { return "Loading…" }
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return "Updated \(formatter.localizedString(for: fetchedAt, relativeTo: now))"
        }
    }

    private func infoItem(label: String, window: UsageWindow?, now: Date) -> NSMenuItem {
        guard let window else { return disabledItem("\(label): no data") }
        let pct = window.effectivePercentage(at: now)
        var title = String(format: "%@: %.0f%%", label, pct)
        if let resetsAt = window.resetsAt, resetsAt > now {
            title += " · resets \(resetDescription(resetsAt, now: now))"
        }
        return disabledItem(title)
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        NSMenuItem(title: title, action: nil, keyEquivalent: "")
    }

    private func resetDescription(_ date: Date, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = date.timeIntervalSince(now) < 23 * 3600 ? "HH:mm" : "EEE HH:mm"
        return formatter.string(from: date)
    }

    @objc private func refreshNow() { refresh(force: true) }

    @objc private func toggleNotifications() {
        notifier.isEnabled.toggle()
        if notifier.isEnabled { notifier.requestAuthorization() }
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Login item toggle failed: \(error)")
        }
    }
}
