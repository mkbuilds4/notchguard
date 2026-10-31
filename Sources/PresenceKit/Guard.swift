import AppKit
import AVFoundation
import Foundation

/// Lets a host app draw the Face ID HUD and face setup in its own UI (NotchNerd's notch).
/// Leave `PresenceGuard.shared.presenter` nil to use PresenceKit's own notch panel.
/// It's also called while the screen is locked, so the host's window must be visible there.
@MainActor
public protocol GuardPresenter: AnyObject {
    func showHUD(_ state: HUDState)
    func hideHUD(after delay: Double)
    /// Setup started; show this session's preview (mirrored, in a circle).
    func enrollmentBegan(session: AVCaptureSession)
    /// `sectorFill`: 8 values 0...1, clockwise from up (up, top right, right, ... top left).
    func enrollmentUpdated(prompt: String, sectorFill: [Double], centerProgress: Double)
    func enrollmentEnded(ok: Bool, message: String)
}

public enum GuardEvent {
    /// You stepped away; the cover is up.
    case away
    /// You're back; the cover is down.
    case back
    /// Someone else, a fake face, or input while away. Photos are already saved.
    case intruder(photos: [URL], reason: String)
    case faceUnlocked
}

/// The embeddable API: what a host app (the standalone menu bar app, NotchNerd) uses.
/// Everything else in PresenceKit is internal.
@MainActor
public final class PresenceGuard {
    public static let shared = PresenceGuard()

    public var onEvent: ((GuardEvent) -> Void)?
    public weak var presenter: GuardPresenter?
    public private(set) var isRunning = false

    private var monitor: Monitor?
    private var task: Task<Void, Never>?
    private var keep: AnyObject?
    private weak var enroller: NotchEnroller?
    private let appLocker = AppLocker()

    private init() {}

    /// Settings, persisted to `~/Library/Application Support/PresenceLock/config.json`. Changes apply on the next start.
    public var config: Config {
        get { Config.load() }
        set {
            newValue.save()
            monitor?.cfg = newValue // the monitor reads settings every pass, so this applies right away
        }
    }

    private var cachedPassword: Data?

    /// Enrollment samples and learned looks (the profile adapts to a growing beard, glasses...).
    public var enrolledSamples: Int { Profile.load()?.samples.count ?? 0 }
    public var learnedLooks: Int { Profile.load()?.learned.count ?? 0 }

    public func forgetLearnedLooks() {
        guard var p = Profile.load() else { return }
        p.learned = []; p.lastLearned = nil
        try? p.save()
        log("forgot learned looks")
    }

    /// Face unlock is armed only after Touch ID releases the stored password into memory.
    public var faceUnlockArmed: Bool { cachedPassword != nil }

    /// Touch ID, then hands the password to the running monitor. Used when face unlock is turned on from Settings.
    public func armFaceUnlock() async -> Bool {
        guard Credentials.isStored, let pw = await Credentials.load(reason: "turn on face unlock") else { return false }
        cachedPassword = pw
        monitor?.password = pw
        return true
    }

    public var faceEnrolled: Bool { Profile.load() != nil }
    public var modelInstalled: Bool { FaceMatcher.modelURL != nil }
    public var passwordStored: Bool { Credentials.isStored }
    public var accessibilityGranted: Bool { KeyTyper.trusted }
    public var isPaused: Bool { FileManager.default.fileExists(atPath: Paths.paused.path) }
    public var intruderPhotos: URL { Alert.folder }

    public func cameraAccess() async -> Bool { await Camera.authorize() }

    /// Starts watching (asks for Touch ID once if face unlock is set up). No-op without a face profile.
    public func start() {
        guard !isRunning, let profile = Profile.load() else { return }
        do {
            let m = try Monitor(profile: profile)
            m.password = cachedPassword
            m.onPasswordLoaded = { [weak self] pw in self?.cachedPassword = pw }
            m.onEvent = { [weak self] e in
                // Walking away relocks any app you'd opened.
                if case .away = e { self?.appLocker.relockAll() }
                self?.onEvent?(e)
            }
            monitor = m
            isRunning = true
            task = Task { @MainActor in
                await m.run()
                m.shutdown()
            }
        } catch {
            log("couldn't start: \(error.localizedDescription)")
        }
    }

    /// Apps that need your face to open (bundle IDs). Watching for them starts with `startAppLock()`.
    public var lockedApps: [String] {
        get { Config.load().lockedApps }
        set { var c = Config.load(); c.lockedApps = newValue; c.save() }
    }

    /// App locking runs independently of the walk-away monitor (it keeps working while paused).
    public func startAppLock() { appLocker.start() }
    public func stopAppLock() { appLocker.stop() }
    public func relockApps() { appLocker.relockAll() }

    public func stop() {
        task?.cancel()
        task = nil
        monitor?.shutdown()
        monitor = nil
        isRunning = false
    }

    public func restart() { stop(); start() }

    public func setPaused(_ paused: Bool) {
        if paused { FileManager.default.createFile(atPath: Paths.paused.path, contents: nil) }
        else { try? FileManager.default.removeItem(at: Paths.paused) }
        log(paused ? "paused" : "resumed")
    }

    /// The notch face setup. Calls back with true once a profile is saved.
    public func enroll(completion: @escaping (Bool) -> Void) {
        Task { @MainActor in
            guard await Camera.authorize() else { completion(false); return }
            do {
                let e = NotchEnroller(matcher: try FaceMatcher(), camera: try Camera(preset: .high))
                e.onFinish = { [weak self] ok in self?.keep = nil; self?.enroller = nil; completion(ok) }
                keep = e
                enroller = e
                e.begin()
            } catch {
                log("enroll failed: \(error.localizedDescription)")
                completion(false)
            }
        }
    }

    /// Stops a face setup in progress without saving.
    public func cancelEnrollment() { enroller?.cancel() }

    /// Downloads InsightFace's MobileFaceNet (only that 13 MB entry of their release zip), checks its
    /// SHA-256, converts it to Core ML on this Mac and installs it. The weights are licensed for
    /// non-commercial research use only, which is why they're fetched rather than shipped.
    public func installModel(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        try await ModelInstaller.install(to: Paths.support.appendingPathComponent("FaceEmbedder.mlmodelc"), progress: progress)
        log("face model installed")
    }

    /// The face unlock password window (checks the password against your account, then asks for Accessibility).
    public func setUpPassword(completion: @escaping (Bool) -> Void) {
        let s = PasswordSetup()
        s.onFinish = { [weak self] ok in self?.keep = nil; completion(ok) }
        keep = s
        s.begin()
    }

    public func removePassword() {
        Credentials.delete()
        cachedPassword = nil
        monitor?.password = nil
    }

    @discardableResult
    public func requestAccessibility() -> Bool { KeyTyper.promptForAccess() }

    /// Touch ID (or the Mac password) before quitting, pausing or turning protection off.
    public static func confirmOwner(reason: String) async -> Bool {
        await Credentials.authenticate(reason: reason)
    }
}
