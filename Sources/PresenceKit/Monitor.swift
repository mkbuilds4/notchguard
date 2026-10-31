import AppKit
import AVFoundation
import CoreGraphics
import Foundation

// MARK: - Monitor

struct Look {
    var me = false
    var bestEmbedding: [Float]?
    var stranger = false
    var faces = 0
    var best: Float = -1
    var detail = "-"
}

/// Main-actor bound: the cover is AppKit UI, and `run()` would otherwise resume on a background executor.
@MainActor
final class Monitor {
    var cfg = Config.load()
    let matcher: FaceMatcher
    let camera: Camera
    let cover = Cover()
    var profile: Profile
    var misses = 0
    var verbose = false
    var loggedFirstCheck = false
    /// Checks in a row that found you while idle; each one stretches the next wait (you're reading, not leaving).
    private var seenInARow = 0
    private var lowPowerCover = false
    /// Mode from places and the schedule, re-read every check.
    private(set) var mode: GuardMode = .normal
    /// Your settings adjusted for the current mode.
    var active: Config { cfg.applying(mode) }

    // Cover mode: the camera runs continuously and we read the newest frame.
    private nonisolated let frameLock = NSLock()
    private nonisolated(unsafe) var newest: CVPixelBuffer?
    private var recent: [CVPixelBuffer] = []
    private var strangerStreak = 0
    private var inputSeenAt: Date?

    // Lock-screen face unlock.
    /// Your login password once Touch ID approved it; the host keeps it across restarts so you aren't asked again.
    var password: Data?
    var onPasswordLoaded: ((Data) -> Void)?
    private var lockedSince: Date?
    private var scanUntil: Date?
    private var unlockCameraOn = false
    /// Unlocking needs intent: you were out of frame for a moment, or you woke the screen / touched a key.
    /// Otherwise locking with Ctrl-Cmd-Q while sitting there would unlock again immediately.
    private var unlockArmed = false
    private var absentSince: Date?
    private var wakeRequested = false
    let hud = FaceHUD()
    /// Lifecycle events for a host app (menu bar, NotchNerd).
    var onEvent: ((GuardEvent) -> Void)?

    /// Called when the run loop is cancelled: put everything away.
    func shutdown() {
        stopFrames(); unlockCameraOn = false
        if cover.isShown { cover.hide(animated: false) }
        hud.hide()
    }
    /// Set by any intruder lock; face unlock stays off until you unlock with your password.
    private var intruderLatched = false

    init(profile: Profile) throws {
        self.profile = profile
        matcher = try FaceMatcher()
        camera = try Camera(preset: .high)
    }

    func look(_ frame: CVPixelBuffer) -> Look {
        let found = matcher.faces(in: frame)
        var l = Look(faces: found.count)
        for face in found {
            let s = profile.score(face.embedding)
            if s > l.best { l.bestEmbedding = face.embedding }
            l.best = max(l.best, s)
            if s >= cfg.threshold { l.me = true }
            if s < cfg.strangerMaxScore && Float(face.bounds.width) >= cfg.strangerMinWidth { l.stranger = true }
        }
        if !found.isEmpty { l.detail = found.map { "\(fmt(profile.score($0.embedding)))@w\(fmt(Float($0.bounds.width)))" }.joined(separator: "/") }
        if l.me { l.stranger = false } // you at the desk with someone beside you is fine
        return l
    }

    /// One short burst. nil = couldn't tell (camera unavailable); never act on that.
    func burstLook() async -> (look: Look, frames: [CVPixelBuffer])? {
        let frames = await camera.burst()
        guard !frames.isEmpty else { return nil }
        let looks = frames.map(look)
        var r = Look()
        r.me = looks.contains { $0.me }
        r.stranger = !r.me && looks.filter(\.stranger).count >= 2
        r.faces = looks.map(\.faces).max() ?? 0
        r.best = looks.map(\.best).max() ?? -1
        r.detail = looks.map(\.detail).joined(separator: " ")
        if verbose { log("frames: \(r.detail)") }
        return (r, frames)
    }

    func run() async {
        log("monitoring: interval \(cfg.interval)s, idleGrace \(cfg.idleGrace)s, missesToLock \(cfg.missesToLock), threshold \(cfg.threshold), cover \(cfg.coverMinutes)m, alerts \(cfg.alertTo.isEmpty ? "off" : "on"), \(profile.samples.count) samples")
        if password == nil && cfg.faceUnlock && Credentials.isStored {
            password = await Credentials.load(reason: "turn on face unlock")
            if let password { onPasswordLoaded?(password) }
            log(password == nil ? "face unlock: not approved, off until restart" : "face unlock: on\(KeyTyper.trusted ? "" : " (but Accessibility not granted yet)")")
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.wakeRequested = true }
            }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screensaver.didstop"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wakeRequested = true }
        }
        var profileStamp = (try? FileManager.default.attributesOfItem(atPath: Paths.profile.path)[.modificationDate]) as? Date
        while !Task.isCancelled {
            // Pick up a re-enrollment without a restart (which would mean another Touch ID prompt).
            let stamp = (try? FileManager.default.attributesOfItem(atPath: Paths.profile.path)[.modificationDate]) as? Date
            if stamp != profileStamp, let p = Profile.load() { profile = p; profileStamp = stamp; log("reloaded face: \(p.samples.count) samples") }
            if cover.isShown { await coveredStep(); continue }
            if screenIsLocked() { misses = 0; await lockedStep(); continue }
            if lockedSince != nil {
                stopFrames(); unlockCameraOn = false
                lockedSince = nil; scanUntil = nil
                if intruderLatched { intruderLatched = false; log("unlocked: face unlock back on") }
            }

            // A miss is confirmed right away; repeated sightings of you back off to save battery.
            let backoff = [1.0, 1.5, 2.5, 3.75][min(seenInARow, 3)]
            try? await Task.sleep(for: .seconds(misses > 0 ? 1 : cfg.interval * backoff))
            if FileManager.default.fileExists(atPath: Paths.paused.path) { misses = 0; continue }
            if screenIsLocked() { continue }
            if !cfg.places.isEmpty || !cfg.schedule.isEmpty {
                PlaceWatcher.shared.start()
                mode = PlaceWatcher.shared.mode(cfg).mode
            } else { mode = .normal }
            let idle = secondsIdle()
            if idle < active.idleGrace { misses = 0; seenInARow = 0; continue }

            guard let (r, frames) = await burstLook() else { log("idle \(Int(idle))s: camera unavailable, skipping"); continue }
            if !loggedFirstCheck { loggedFirstCheck = true; log("first check ok: \(r.faces) face(s), best \(fmt(r.best))") }
            if r.me { misses = 0; seenInARow += 1; continue }
            seenInARow = 0
            // A dark room hides your face from the camera; that's not walking away. After two idle minutes it counts.
            if r.faces == 0, idle < 120, let b = frames.last.map(brightness), b < cfg.darkFrame {
                misses = 0
                log("idle \(Int(idle))s: too dark to tell (brightness \(fmt(b))), not counting as away")
                continue
            }
            if r.stranger { intruder("someone else at the Mac (\(r.detail))", frames: frames); continue }
            misses += 1
            log("idle \(Int(idle))s: \(r.faces == 0 ? "no face" : "not you (\(r.detail))"), miss \(misses)/\(active.missesToLock)")
            if misses >= active.missesToLock { mode == .strict || cfg.lockInsteadOfCover ? lockNow("away (\(mode == .strict ? "strict mode" : "lock instead of cover")): locking") : enterCover() }
        }
    }

    // MARK: cover mode

    func enterCover() {
        let coverMinutes = active.coverMinutes
        log("away: cover up" + (coverMinutes > 0 ? ", real lock in \(coverMinutes)m" : "") + (mode == .normal ? "" : " (\(mode.rawValue))"))
        misses = 0; strangerStreak = 0; inputSeenAt = nil
        frameLock.withLock { newest = nil; recent = [] }
        cover.show(lockAfter: coverMinutes > 0 ? coverMinutes * 60 : nil)
        onEvent?(.away)
        startFrames()
    }

    func exitCover(_ why: String) {
        onEvent?(.back)
        camera.stop()
        if lowPowerCover { lowPowerCover = false; camera.setFrameRate(nil) }
        frameLock.withLock { newest = nil; recent = [] }
        cover.hide()
        log(why)
    }

    func startFrames() {
        camera.start { [weak self] pb in
            guard let self else { return }
            self.frameLock.withLock { self.newest = pb }
        }
    }

    func stopFrames() {
        camera.stop()
        if lowPowerCover { lowPowerCover = false; camera.setFrameRate(nil) }
        frameLock.withLock { newest = nil; recent = [] }
    }

    /// Average brightness 0...1 of a BGRA frame, sampled sparsely.
    nonisolated func brightness(_ pb: CVPixelBuffer) -> Float {
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return 1 }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0, n = 0
        for y in stride(from: 0, to: h, by: 16) {
            for x in stride(from: 0, to: w, by: 16) {
                let i = y * row + x * 4
                sum += Int(p[i]) + Int(p[i + 1]) + Int(p[i + 2]); n += 3
            }
        }
        return n == 0 ? 1 : Float(sum) / Float(n * 255)
    }

    nonisolated func newestFrame() -> CVPixelBuffer? { frameLock.withLock { newest } }

    private func coveredStep() async {
        try? await Task.sleep(for: .milliseconds(500))
        if FileManager.default.fileExists(atPath: Paths.paused.path) { exitCover("paused: cover down"); return }
        if screenIsLocked() { exitCover("screen locked elsewhere: cover down"); return }
        let away = Date().timeIntervalSince(cover.since)
        // Away more than a minute: 5 fps is plenty to notice you coming back, and far cheaper.
        if away > 60 && !lowPowerCover { lowPowerCover = true; camera.setFrameRate(5) }
        if active.coverMinutes > 0 && away >= active.coverMinutes * 60 { lockNow("away \(Int(away))s: locking"); return }

        guard let frame = frameLock.withLock({ newest }) else { return }
        frameLock.withLock { recent = Array((recent + [frame]).suffix(3)) }
        let l = look(frame)
        if l.me {
            guard cfg.liveness else { exitCover("you're back after \(Int(away))s (score \(fmt(l.best))): cover down"); return }
            hud.show(.scanning("Looking for you"))
            let (verdict, ev) = await checkLive(seconds: 6, cover: cover)
            switch verdict {
            case .live:
                hud.show(.success("Welcome back")); hud.hide(after: 0.8)
                learnLook(ev)
                exitCover("you're back after \(Int(away))s, live check passed (\(ev.summary)): cover down")
            case .spoof(let why):
                hud.show(.failure("Not a real face")); hud.hide(after: 2)
                intruder("fake face: \(why) (\(ev.summary))", frames: frameLock.withLock { recent })
            case .inconclusive: hud.hide(); log("live check inconclusive (\(ev.summary)), retrying"); cover.setMessage(nil)
            }
            return
        }

        strangerStreak = l.stranger ? strangerStreak + 1 : 0
        if strangerStreak >= 2 { intruder("someone else in front of the cover (\(l.detail))", frames: frameLock.withLock { recent }); return }

        // Keyboard or mouse touched while you're not in frame.
        if secondsIdle() < Date().timeIntervalSince(cover.since) - 1 {
            if inputSeenAt == nil { inputSeenAt = Date() }
            if Date().timeIntervalSince(inputSeenAt!) > 2 {
                intruder("keyboard/mouse used while away (\(l.faces == 0 ? "no face" : l.detail))", frames: frameLock.withLock { recent })
            }
        }
    }

    /// After a confident live match, keep that look of you so gradual changes (beard, glasses) don't drift out of range.
    func learnLook(_ ev: Liveness) {
        guard let e = ev.bestEmbedding, ev.best >= cfg.learnScore else { return }
        var p = profile
        guard p.learn(e, every: 600) else { return }
        do { try p.save(); profile = p; log("learned a new look (score \(fmt(ev.best)), \(p.learned.count)/\(Profile.maxLearned) kept)") }
        catch { log("couldn't save learned look: \(error.localizedDescription)") }
    }

    // MARK: lock screen

    private func lockedStep() async {
        if lockedSince == nil {
            lockedSince = Date()
            scanUntil = Date().addingTimeInterval(cfg.unlockLookSeconds)
            unlockArmed = false; absentSince = nil; wakeRequested = false
        }
        let paused = FileManager.default.fileExists(atPath: Paths.paused.path)
        guard cfg.faceUnlock, password != nil, !intruderLatched, !paused, KeyTyper.trusted else {
            if unlockCameraOn { stopFrames(); unlockCameraOn = false }
            try? await Task.sleep(for: .seconds(1))
            return
        }
        // Waking the screen or touching a key/trackpad: look again, and that counts as intent to unlock.
        // Input in the first 2s is the lock shortcut itself (Ctrl-Cmd-Q), not a request to unlock.
        let touched = secondsIdle() < 1.5 && Date().timeIntervalSince(lockedSince!) > 2
        if wakeRequested || touched {
            wakeRequested = false
            scanUntil = Date().addingTimeInterval(cfg.unlockLookSeconds)
            unlockArmed = true
        }
        guard let until = scanUntil, Date() < until else {
            if unlockCameraOn { stopFrames(); unlockCameraOn = false; hud.hide() }
            try? await Task.sleep(for: .milliseconds(300))
            return
        }
        if !unlockCameraOn { startFrames(); unlockCameraOn = true }
        try? await Task.sleep(for: .milliseconds(120))
        guard let frame = newestFrame() else { return }
        frameLock.withLock { recent = Array((recent + [frame]).suffix(3)) }
        guard look(frame).me else {
            if absentSince == nil { absentSince = Date() }
            if Date().timeIntervalSince(absentSince!) > 1.5 { unlockArmed = true }
            return
        }
        absentSince = nil
        guard unlockArmed else { return }

        hud.show(.scanning("Looking for you"))
        let (verdict, ev) = cfg.liveness ? await checkLive(seconds: 6, cover: nil) : (.live, Liveness())
        switch verdict {
        case .live:
            guard screenIsLocked() else { hud.hide(); return }
            hud.show(.success("Welcome back"))
            log("face unlock: it's you and live (\(ev.summary)), unlocking")
            onEvent?(.faceUnlocked)
            learnLook(ev)
            stopFrames(); unlockCameraOn = false
            let pw = password!
            let typed = await Task.detached { KeyTyper.unlock(with: pw) }.value
            hud.hide(after: 0.6)
            try? await Task.sleep(for: .seconds(2))
            if !typed { log("face unlock: couldn't type (Accessibility?)") }
            else if screenIsLocked() { log("face unlock: still locked after typing; waiting for a wake or key press"); scanUntil = Date(); unlockArmed = false }
        case .spoof(let why):
            intruderLatched = true
            hud.show(.failure("Not a real face"))
            hud.hide(after: 2)
            stopFrames(); unlockCameraOn = false
            let photos = Alert.save(frameLock.withLock { recent })
            onEvent?(.intruder(photos: photos, reason: "fake face at the lock screen: \(why)"))
            log("INTRUDER at lock screen: fake face, \(why) (\(ev.summary)); face unlock off until you type your password")
            if !cfg.alertTo.isEmpty {
                Alert.send(to: cfg.alertTo, text: "NotchGuard: someone tried to unlock your Mac with a fake face (\(why)) at \(Date().formatted(date: .omitted, time: .standard)). Face unlock is off until you type your password.", photos: photos)
            }
        case .inconclusive:
            hud.hide()
        }
    }

    // MARK: actions

    private func lockNow(_ why: String) {
        log(why)
        lockScreen()
        camera.stop()
        frameLock.withLock { newest = nil; recent = [] }
        misses = 0; strangerStreak = 0; inputSeenAt = nil
        // Let the lock screen come up before the cover goes away.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [cover] in cover.hide(animated: false) }
    }

    private func intruder(_ why: String, frames: [CVPixelBuffer]) {
        intruderLatched = true
        let photos = Alert.save(frames)
        onEvent?(.intruder(photos: photos, reason: why))
        lockNow("INTRUDER: \(why); locking, \(photos.count) photo(s) saved")
        guard !cfg.alertTo.isEmpty else { return }
        let when = Date().formatted(date: .omitted, time: .standard)
        Alert.send(to: cfg.alertTo, text: "NotchGuard: someone else was at your Mac at \(when). It's locked now.", photos: photos)
    }
}

