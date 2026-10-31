import AppKit
import Foundation

/// Keeps chosen apps behind your face: when one comes forward it's hidden under a cover until
/// a live check sees you (or Touch ID after two failed looks). Unlocked apps lock again when
/// you walk away, the Mac locks, or the app quits.
@MainActor
final class AppLocker {
    private var unlocked: Set<String> = []
    /// When you last switched away from each unlocked app (for the relock timer).
    private var leftAt: [String: Date] = [:]
    private var checking: String?
    private var observers: [NSObjectProtocol] = []

    var lockedApps: [String] { Config.load().lockedApps }

    func start() {
        guard observers.isEmpty else { return }
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.activated(app) }
        })
        // Launches too (FaceGate does both): an app can open in the background without activating.
        observers.append(ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.activated(app) }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let id = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier else { return }
            MainActor.assumeIsolated { if self?.unlocked.contains(id) == true { self?.leftAt[id] = Date() } }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let id = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier else { return }
            MainActor.assumeIsolated { _ = self?.unlocked.remove(id) }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.relockAll() }
        })
        // A locked app that's already frontmost when protection starts.
        if let front = NSWorkspace.shared.frontmostApplication { activated(front) }
    }

    func stop() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); DistributedNotificationCenter.default().removeObserver($0) }
        observers = []
    }

    func relockAll() {
        guard !unlocked.isEmpty else { return }
        log("app lock: relocking \(unlocked.count) app(s)")
        unlocked.removeAll()
        // Anything locked that's still in front gets challenged again.
        if let front = NSWorkspace.shared.frontmostApplication { activated(front) }
    }

    private func activated(_ app: NSRunningApplication) {
        guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier, lockedApps.contains(id),
              checking == nil, !screenIsLocked() else { return }
        // Unlocked, but you've been out of it longer than the relock setting: ask again.
        let relock = Config.load().appRelockMinutes
        if unlocked.contains(id), relock > 0, let left = leftAt[id], Date().timeIntervalSince(left) > relock * 60 {
            unlocked.remove(id)
            log("app lock: \(app.localizedName ?? id) relocked after \(Int(relock)) min away from it")
        }
        guard !unlocked.contains(id) else { return }
        checking = id
        app.hide()
        Task { await challenge(app, id: id) }
    }

    // MARK: one challenge at a time

    private enum Outcome { case open, quit, stay }
    private var current: (app: NSRunningApplication, id: String, monitor: Monitor?)?
    private var done = false

    private func challenge(_ app: NSRunningApplication, id: String) async {
        let name = app.localizedName ?? id
        let icon = app.icon ?? NSWorkspace.shared.icon(forFile: app.bundleURL?.path ?? "/Applications")
        done = false
        current = (app, id, nil)
        guard let profile = Profile.load(), let m = try? Monitor(profile: profile), await Camera.authorize() else {
            touchID(name)
            return
        }
        current = (app, id, m)
        m.cover.show(lockAfter: nil, app: (name, icon), actions: [
            ("Use Touch ID", { [weak self] in self?.touchID(name) }),
            ("Quit \(name)", { [weak self] in self?.finish(.quit) }),
        ])
        m.startFrames()
        try? await Task.sleep(for: .milliseconds(500))
        for _ in 0..<2 {
            if done { return }
            m.hud.show(.scanning("Looking for you"))
            let (verdict, ev) = await m.checkLive(seconds: 6, cover: m.cover)
            if done { return }
            switch verdict {
            case .live:
                m.hud.show(.success("Opening \(name)"))
                log("app lock: opened \(name) (\(ev.summary))")
                finish(.open)
                return
            case .spoof(let why):
                m.hud.show(.failure("Not a real face"))
                log("app lock: \(name) blocked, fake face: \(why) (\(ev.summary))")
            case .inconclusive:
                m.hud.show(.failure("Not recognized"))
            }
        }
        if done { return }
        // Two looks failed: camera off, cover stays with its buttons, and Touch ID is offered once.
        m.stopFrames()
        m.hud.hide(after: 1)
        m.cover.setMessage("Use Touch ID, or quit \(name)")
        touchID(name)
    }

    private func touchID(_ name: String) {
        Task {
            let ok = await Credentials.authenticate(reason: "open \(name)")
            log("app lock: \(name) \(ok ? "opened with Touch ID" : "Touch ID cancelled")")
            if ok { finish(.open) } else if current?.monitor == nil { finish(.stay) }
        }
    }

    private func finish(_ outcome: Outcome) {
        guard !done, let c = current else { return }
        done = true
        if let m = c.monitor {
            m.stopFrames()
            m.hud.hide(after: 0.6)
            m.cover.hide()
        }
        switch outcome {
        case .open:
            unlocked.insert(c.id)
            leftAt[c.id] = nil
            c.app.unhide()
            c.app.activate()
        case .quit:
            // Like FaceGate's cancel: the locked app is closed, forcibly if it doesn't go within a second.
            log("app lock: quit \(c.app.localizedName ?? c.id)")
            c.app.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if !c.app.isTerminated { c.app.forceTerminate() } }
        case .stay:
            break
        }
        current = nil
        checking = nil
    }
}
