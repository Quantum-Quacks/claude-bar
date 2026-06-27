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

    private var accountUserID: String?

    // Per-saved-account usage shown in the Accounts submenu, keyed by profile name.
    private struct AccountUsage { var usage: Usage?; var error: UsageError?; var fetchedAt: Date }
    private var accountUsage: [String: AccountUsage] = [:]
    private var accountFetchInFlight: Set<String> = []
    private var accountRowItems: [String: NSMenuItem] = [:]
    private var accountRowInfo: [String: AccountStore.Listed] = [:]
    private weak var accountsSubmenu: NSMenu?
    /// Re-use a fetched figure for this long; back off longer after a failure so
    /// a revoked token isn't poked repeatedly.
    private let accountUsageTTL: TimeInterval = 120
    private let accountErrorTTL: TimeInterval = 600

    /// Decrypted access tokens kept in memory so the keychain is read at most
    /// once per token lifetime instead of on every poll or menu open — that read
    /// is what triggers the macOS permission prompt. Invalidated when the active
    /// account changes or a token is rejected.
    private struct CachedToken { let token: String; let plan: String?; let expiresAt: Date? }
    private var liveToken: CachedToken?
    private var liveTokenEmail: String?
    private var profileTokens: [String: CachedToken] = [:]

    private func isActiveAccount(_ account: AccountStore.Listed) -> Bool {
        // Match on email only — that's the per-account identity. The `userID` in
        // ~/.claude.json is a per-machine id shared by every account, so matching
        // on it marks ALL saved accounts active and blocks switching.
        guard let email = accountEmail, let other = account.email else { return false }
        return email == other
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        render()

        accountEmail = UsageClient.accountEmail()
        accountUserID = AccountStore.activeUserID()
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
        // Only overwrite identity when the read succeeds — ~/.claude.json is
        // rewritten constantly by Claude Code, so a wake that lands mid-rewrite
        // would otherwise blank these out.
        if let email = UsageClient.accountEmail() { accountEmail = email }
        if let userID = AccountStore.activeUserID() { accountUserID = userID }
        // Keep the cached token across sleep. A rotation by Claude Code while we
        // slept does NOT invalidate the access token we already hold (it stays
        // valid until its own expiry), and a genuinely rejected token re-reads
        // via the .unauthorized path below. Clearing it here forced a keychain
        // read — and a macOS permission prompt — on every single wake.
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
            guard let self else { completion?(); return }
            let result = await self.fetchLiveUsage()
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

    /// Usage for the active account, reading the keychain only when the cached
    /// token is missing, near expiry, or rejected — so a steady poll doesn't
    /// re-prompt every few minutes.
    private func fetchLiveUsage() async -> Result<Usage, UsageError> {
        // Drop the cached token only when the active account genuinely changes —
        // i.e. a *different, known* email. accountEmail() reads ~/.claude.json,
        // which Claude Code rewrites constantly; a nil here means we caught it
        // mid-rewrite, not that the account changed. Treating that nil as a
        // change is what discarded a good token and forced a fresh keychain read
        // (a permission prompt) on the next poll or menu open.
        if let email = UsageClient.accountEmail(), liveTokenEmail != email {
            liveToken = nil
            liveTokenEmail = email
        }

        if let cached = liveToken, let expiry = cached.expiresAt,
           expiry.timeIntervalSinceNow > 600 {
            let result = await UsageClient.usage(accessToken: cached.token, plan: cached.plan)
            if case .failure(.unauthorized) = result {
                liveToken = nil          // died early — fall through and re-read
            } else {
                return result
            }
        }
        guard let creds = UsageClient.liveCredentials() else { return .failure(.noToken) }
        liveToken = CachedToken(token: creds.token, plan: creds.plan, expiresAt: creds.expiresAt)
        return await UsageClient.usage(accessToken: creds.token, plan: creds.plan)
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
        if menu === accountsSubmenu { return }
        refresh(force: false)   // exact read when you look, throttled
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === accountsSubmenu {
            rebuildAccountsSubmenu(menu)
            kickAccountUsageFetches()
            return
        }
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
        menu.addItem(accountsMenu())

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

    // MARK: - Accounts

    /// "Accounts" submenu: one row per saved profile (✓ on the active one) with
    /// its live usage, plus "Save Current Account As…". Hold ⌥ to turn a row into
    /// "Remove". Rows are filled in here; usage is fetched lazily when the
    /// submenu opens (see menuNeedsUpdate).
    private func accountsMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Accounts", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.delegate = self
        accountsSubmenu = submenu
        parent.submenu = submenu
        rebuildAccountsSubmenu(submenu)   // never show a blank submenu
        return parent
    }

    private func rebuildAccountsSubmenu(_ submenu: NSMenu) {
        submenu.removeAllItems()
        accountRowItems.removeAll()
        accountRowInfo.removeAll()
        let saved = AccountStore.list()

        if saved.isEmpty {
            submenu.addItem(disabledItem("No saved accounts yet"))
        } else {
            for account in saved {
                // Parent shows status (✓ + usage); its submenu holds the actions.
                let parent = NSMenuItem(title: accountRowTitle(account), action: nil, keyEquivalent: "")
                if isActiveAccount(account) { parent.state = .on }
                parent.submenu = accountActionsMenu(for: account)
                submenu.addItem(parent)
                accountRowItems[account.name] = parent
                accountRowInfo[account.name] = account
            }
        }

        submenu.addItem(.separator())
        let save = NSMenuItem(
            title: "Save Current Account As…",
            action: #selector(saveCurrentAccount), keyEquivalent: "")
        save.target = self
        submenu.addItem(save)
    }

    /// Per-account action submenu: switch to it, rename it, or delete it.
    private func accountActionsMenu(for account: AccountStore.Listed) -> NSMenu {
        let menu = NSMenu()
        if isActiveAccount(account) {
            menu.addItem(disabledItem("Cuenta activa"))
        } else {
            let use = NSMenuItem(
                title: "Usar esta cuenta", action: #selector(switchAccount(_:)), keyEquivalent: "")
            use.target = self
            use.representedObject = account.name
            menu.addItem(use)
        }
        menu.addItem(.separator())
        let rename = NSMenuItem(
            title: "Renombrar…", action: #selector(renameAccount(_:)), keyEquivalent: "")
        rename.target = self
        rename.representedObject = account.name
        menu.addItem(rename)
        let remove = NSMenuItem(
            title: "Eliminar", action: #selector(removeAccount(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = account.name
        menu.addItem(remove)
        return menu
    }

    private func accountDisplay(_ account: AccountStore.Listed) -> String {
        var title = account.name
        if let email = account.email, email != account.name { title += " · \(email)" }
        if let plan = account.plan, !plan.isEmpty { title += " (\(plan.capitalized))" }
        return title
    }

    private func accountRowTitle(_ account: AccountStore.Listed) -> String {
        var title = accountDisplay(account)
        if let usageText = accountUsageText(for: account) { title += "  —  \(usageText)" }
        return title
    }

    /// Usage suffix for an account row: the live figure for the active account,
    /// the cached/refreshed figure otherwise, or a short status while loading or
    /// after a failure.
    private func accountUsageText(for account: AccountStore.Listed) -> String? {
        if isActiveAccount(account) {
            return usage.map { usageSummary($0) } ?? "…"
        }
        if accountUsage[account.name] == nil, accountFetchInFlight.contains(account.name) {
            return "…"
        }
        guard let entry = accountUsage[account.name] else { return nil }
        if let usage = entry.usage { return usageSummary(usage) }
        switch entry.error {
        case .unauthorized, .noToken: return "sesión expirada · re-login"
        case .rateLimited: return "rate limited"
        default: return "sin conexión"
        }
    }

    private func usageSummary(_ usage: Usage) -> String {
        let now = Date()
        var parts: [String] = []
        if let pct = usage.fiveHour?.effectivePercentage(at: now) {
            var text = String(format: "5h %.0f%%", pct)
            if let resets = usage.fiveHour?.resetsAt, resets > now {
                text += " (→\(resetDescription(resets, now: now)))"   // sesión 5h activa
            }
            parts.append(text)
        }
        if let pct = usage.sevenDay?.effectivePercentage(at: now) {
            parts.append(String(format: "7d %.0f%%", pct))
        }
        return parts.isEmpty ? "sin datos" : parts.joined(separator: " · ")
    }

    private func kickAccountUsageFetches() {
        for account in accountRowInfo.values { triggerAccountUsageFetch(account) }
    }

    /// Refresh-and-fetch usage for one saved account, throttled by TTL and
    /// deduped by an in-flight set. Skips the active account (it shows live).
    private func triggerAccountUsageFetch(_ account: AccountStore.Listed) {
        if isActiveAccount(account) { return }
        let name = account.name
        if accountFetchInFlight.contains(name) { return }
        if let entry = accountUsage[name] {
            let ttl = entry.error == nil ? accountUsageTTL : accountErrorTTL
            if Date().timeIntervalSince(entry.fetchedAt) < ttl { return }
        }
        accountFetchInFlight.insert(name)
        Task { [weak self] in
            guard let self else { return }
            // Reuse an in-memory token while it's valid — no keychain, no prompt.
            var creds: (token: String, plan: String?)?
            if let cached = self.profileTokens[name], let expiry = cached.expiresAt,
               expiry.timeIntervalSinceNow > 600 {
                creds = (cached.token, cached.plan)
            } else if let fresh = await AccountStore.freshAccessToken(for: name) {
                self.profileTokens[name] = CachedToken(
                    token: fresh.token, plan: fresh.plan, expiresAt: fresh.expiresAt)
                creds = (fresh.token, fresh.plan)
            }

            let entry: AccountUsage
            if let creds {
                switch await UsageClient.usage(accessToken: creds.token, plan: creds.plan) {
                case .success(let usage):
                    entry = AccountUsage(usage: usage, error: nil, fetchedAt: Date())
                case .failure(let error):
                    if case .unauthorized = error { self.profileTokens[name] = nil }
                    entry = AccountUsage(usage: nil, error: error, fetchedAt: Date())
                }
            } else {
                entry = AccountUsage(usage: nil, error: .unauthorized, fetchedAt: Date())
            }
            self.accountFetchInFlight.remove(name)
            self.accountUsage[name] = entry
            self.updateAccountRow(name)
        }
    }

    /// Update one row's title in place (no rebuild) when its usage lands.
    private func updateAccountRow(_ name: String) {
        guard let item = accountRowItems[name], let info = accountRowInfo[name] else { return }
        item.title = accountRowTitle(info)
    }

    @objc private func switchAccount(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        do {
            try AccountStore.activate(name)
            accountEmail = UsageClient.accountEmail()
            accountUserID = AccountStore.activeUserID()
            liveToken = nil           // active token changed — re-read on next poll
            notifier.reset()          // new account, fresh thresholds
            usage = nil               // drop the old account's bars until the refetch lands
            render()
            refresh(force: true)
        } catch {
            presentError("Couldn’t switch account", error)
        }
    }

    @objc private func saveCurrentAccount() {
        guard let name = promptForAccountName() else { return }
        do {
            try AccountStore.saveCurrent(as: name)
        } catch {
            presentError("Couldn’t save account", error)
        }
    }

    @objc private func removeAccount(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "¿Eliminar la cuenta guardada “\(name)”?"
        alert.informativeText = "Se borra el perfil guardado. No afecta a la sesión de Claude Code activa."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Eliminar")
        alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        AccountStore.remove(name)
        forgetAccountCaches(name)
    }

    @objc private func renameAccount(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        guard let newName = promptForName(
            title: "Renombrar cuenta",
            message: "Nuevo nombre para “\(name)”.",
            initial: name), newName != name
        else { return }
        do {
            try AccountStore.rename(name, to: newName)
            if let usage = accountUsage.removeValue(forKey: name) { accountUsage[newName] = usage }
            if let token = profileTokens.removeValue(forKey: name) { profileTokens[newName] = token }
            accountFetchInFlight.remove(name)
        } catch {
            presentError("No se pudo renombrar", error)
        }
    }

    /// Drop any in-memory state for a profile that's been removed/renamed.
    private func forgetAccountCaches(_ name: String) {
        accountUsage[name] = nil
        profileTokens[name] = nil
        accountFetchInFlight.remove(name)
    }

    /// Modal text prompt seeded with `initial`; nil if cancelled or left empty.
    private func promptForName(title: String, message: String, initial: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Guardar")
        alert.addButton(withTitle: "Cancelar")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Modal name prompt, pre-filled with the active account's email local-part.
    private func promptForAccountName() -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Save current Claude account"
        alert.informativeText = "Name this profile so you can switch back to it later."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "e.g. work, personal"
        if let email = accountEmail {
            field.stringValue = String(email.prefix(while: { $0 != "@" }))
        }
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private func presentError(_ title: String, _ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
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
