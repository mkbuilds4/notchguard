import AppKit
import PresenceKit
import ServiceManagement

/// The standalone app: a menu bar icon with status, pause, setup and Touch ID-protected quit.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let guardian = PresenceGuard.shared
    private var pauseUntil: Date?
    private var resumeTimer: Timer?
    private let settings = SettingsWindow()
    private let onboarding = OnboardingWindow()

    override init() {
        super.init()
        item.button?.image = NSImage(systemSymbolName: "faceid", accessibilityDescription: "NotchGuard")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        guardian.onEvent = { [weak self] event in self?.handle(event) }
        if guardian.faceEnrolled { guardian.start() } else { DispatchQueue.main.async { self.firstRun() } }
        guardian.startAppLock()
        // macOS drops status items that don't fit beside the notch; say how to get in if ours is one of them.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.warnIfHidden() }
        refreshIcon()
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(disabled(statusText()))
        menu.addItem(.separator())

        if guardian.faceEnrolled {
            if guardian.isPaused {
                menu.addItem(action("Resume", #selector(resume)))
            } else {
                menu.addItem(action("Pause for 1 Hour", #selector(pauseHour)))
                menu.addItem(action("Pause Until I Resume", #selector(pauseIndefinitely)))
            }
            menu.addItem(.separator())
        }

        if !guardian.faceEnrolled {
            menu.addItem(action("Set Up NotchGuard…", #selector(setUp)))
            menu.addItem(.separator())
        }
        menu.addItem(action("Intruder Photos…", #selector(openPhotos)))
        menu.addItem(action("Settings…", #selector(openSettingsWindow), key: ","))
        menu.addItem(.separator())
        menu.addItem(action("Quit NotchGuard", #selector(quit), key: "q"))
    }

    private func statusText() -> String {
        if !guardian.faceEnrolled { return "Set up your face to start" }
        if guardian.isPaused {
            if let until = pauseUntil { return "Paused until \(until.formatted(date: .omitted, time: .shortened))" }
            return "Paused"
        }
        return guardian.isRunning ? "Watching while you're away" : "Not running"
    }

    private func faceUnlockTitle() -> String {
        if !guardian.passwordStored { return "Turn On Face Unlock…" }
        return guardian.accessibilityGranted ? "Face Unlock: On (Change…)" : "Face Unlock: Needs Accessibility…"
    }

    private func action(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func refreshIcon() {
        let name = !guardian.faceEnrolled || guardian.isPaused ? "faceid" : "faceid"
        item.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "NotchGuard")
        item.button?.appearsDisabled = guardian.isPaused || !guardian.isRunning
    }

    // MARK: actions

    private func firstRun() {
        onboarding.onFinish = { [weak self] in
            guard let self else { return }
            self.guardian.start()
            self.refreshIcon()
        }
        onboarding.show()
    }

    @objc private func setUp() { firstRun() }

    @objc private func enroll() {
        guard guardian.modelInstalled else { installModelThenEnroll(); return }
        let wasRunning = guardian.isRunning
        guardian.stop()
        guardian.enroll { [weak self] ok in
            guard let self else { return }
            if ok || wasRunning { self.guardian.start() }
            self.refreshIcon()
            if ok && !self.guardian.passwordStored { self.offerFaceUnlock() }
        }
    }

    /// First run on a public build: fetch and convert the face model (about 13 MB, under a minute), then set up.
    private func installModelThenEnroll() {
        item.button?.appearsDisabled = true
        Task {
            do {
                try await guardian.installModel()
                enroll()
            } catch {
                let a = NSAlert()
                a.messageText = "Couldn't download the face model"
                a.informativeText = "\(error.localizedDescription)\n\nCheck your connection and try Set Up My Face again."
                NSApp.activate(ignoringOtherApps: true)
                a.runModal()
            }
            refreshIcon()
        }
    }

    private func warnIfHidden() {
        guard let w = item.button?.window, !w.occlusionState.contains(.visible) else { return }
        log("menu bar icon is hidden (menu bar full)")
        let n = NSUserNotification()
        n.title = "NotchGuard is running"
        n.informativeText = "Your menu bar is full, so its icon is hidden. Open NotchGuard again from Spotlight to see its settings."
        NSUserNotificationCenter.default.deliver(n)
    }

    private func offerFaceUnlock() {
        let a = NSAlert()
        a.messageText = "Unlock with your face too?"
        a.informativeText = "NotchGuard can unlock the lock screen when it sees you and you blink. It stores your Mac password in your login keychain, loads it only after Touch ID, and types it at the lock screen (this needs the Accessibility permission).\n\nA MacBook camera can't see depth, so this is a convenience, not Face ID."
        a.addButton(withTitle: "Turn On")
        a.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { faceUnlock() }
    }

    @objc private func faceUnlock() {
        if guardian.passwordStored && !guardian.accessibilityGranted { guardian.requestAccessibility(); return }
        guardian.setUpPassword { [weak self] ok in
            // The monitor loads the password (with Touch ID) when it starts.
            if ok { self?.guardian.restart() }
        }
    }

    @objc private func pauseHour() {
        Task {
            guard await PresenceGuard.confirmOwner(reason: "pause NotchGuard") else { return }
            guardian.setPaused(true)
            pauseUntil = Date().addingTimeInterval(3600)
            resumeTimer?.invalidate()
            resumeTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume() }
            }
            refreshIcon()
        }
    }

    @objc private func pauseIndefinitely() {
        Task {
            guard await PresenceGuard.confirmOwner(reason: "pause NotchGuard") else { return }
            guardian.setPaused(true)
            pauseUntil = nil
            refreshIcon()
        }
    }

    @objc private func resume() {
        resumeTimer?.invalidate()
        pauseUntil = nil
        guardian.setPaused(false)
        refreshIcon()
    }

    @objc private func openPhotos() { NSWorkspace.shared.open(guardian.intruderPhotos) }

    func showSettings() { openSettingsWindow() }

    @objc private func openSettingsWindow() {
        Task {
            // Settings can turn protection off, so they need the owner.
            guard await PresenceGuard.confirmOwner(reason: "open NotchGuard settings") else { return }
            settings.show()
        }
    }

    @objc private func openSettings() {
        guardian.config = guardian.config // make sure the file exists with every setting
        NSWorkspace.shared.open(Paths.config)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            log("open at login: \(error.localizedDescription)")
        }
    }

    @objc private func quit() {
        Task {
            // Tamper protection: someone at your Mac can't just quit it.
            guard await PresenceGuard.confirmOwner(reason: "quit NotchGuard") else { return }
            guardian.stop()
            NSApp.terminate(nil)
        }
    }

    private func handle(_ event: GuardEvent) {
        if case .intruder = event { refreshIcon() }
    }
}
