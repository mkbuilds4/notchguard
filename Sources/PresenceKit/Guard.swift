import AppKit
import Foundation

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
    public private(set) var isRunning = false

    private var monitor: Monitor?
    private var task: Task<Void, Never>?
    private var keep: AnyObject?

    private init() {}

    /// Settings, persisted to `~/Library/Application Support/PresenceLock/config.json`. Changes apply on the next start.
    public var config: Config {
        get { Config.load() }
        set { newValue.save() }
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
            m.onEvent = { [weak self] e in self?.onEvent?(e) }
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
                e.onFinish = { [weak self] ok in self?.keep = nil; completion(ok) }
                keep = e
                e.begin()
            } catch {
                log("enroll failed: \(error.localizedDescription)")
                completion(false)
            }
        }
    }

    /// The face unlock password window (checks the password against your account, then asks for Accessibility).
    public func setUpPassword(completion: @escaping (Bool) -> Void) {
        let s = PasswordSetup()
        s.onFinish = { [weak self] ok in self?.keep = nil; completion(ok) }
        keep = s
        s.begin()
    }

    public func removePassword() { Credentials.delete() }

    @discardableResult
    public func requestAccessibility() -> Bool { KeyTyper.promptForAccess() }

    /// Touch ID (or the Mac password) before quitting, pausing or turning protection off.
    public static func confirmOwner(reason: String) async -> Bool {
        await Credentials.authenticate(reason: reason)
    }
}
