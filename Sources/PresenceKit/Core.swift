import AppKit
import AVFoundation
import CoreGraphics
import Foundation

// MARK: - Paths, config, log

public enum Paths {
    public static let support: URL = {
        // PLOCK_HOME points everything at a scratch folder (testing onboarding as a new user).
        if let home = ProcessInfo.processInfo.environment["PLOCK_HOME"] {
            let u = URL(fileURLWithPath: home)
            try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            return u
        }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return moved(dir.appendingPathComponent("PresenceLock"), to: dir.appendingPathComponent("NotchGuard"))
    }()
    public static let profile = support.appendingPathComponent("profile.json")
    public static let config = support.appendingPathComponent("config.json")
    public static let paused = support.appendingPathComponent("paused")
    public static let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/NotchGuard.log")

    /// A folder from before the rename to NotchGuard, moved to its new name the first time it's needed.
    static func moved(_ old: URL, to new: URL) -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: new.path), fm.fileExists(atPath: old.path) { try? fm.moveItem(at: old, to: new) }
        try? fm.createDirectory(at: new, withIntermediateDirectories: true)
        return new
    }
}

public struct Config: Codable, Equatable {
    public init() {}
    /// Seconds between checks while you're idle.
    public var interval: Double = 4
    /// Keyboard/mouse activity within this many seconds counts as present; the camera stays off.
    public var idleGrace: Double = 10
    /// Consecutive checks without you before the cover goes up.
    public var missesToLock: Int = 2
    /// Cosine similarity against your enrolled samples needed to count as you.
    public var threshold: Float = 0.30
    /// A face scoring below this (well under `threshold`) is someone else; the band between is ambiguous.
    public var strangerMaxScore: Float = 0.20
    /// A face at least this wide (fraction of the frame) is sitting at the Mac, not passing in the background.
    public var strangerMinWidth: Float = 0.15
    /// Minutes the cover stays up before the real lock; 0 = no limit.
    public var coverMinutes: Double = 0
    /// Bundle IDs of apps that need your face (or Touch ID) to open.
    public var lockedApps: [String] = []
    /// Lock an unlocked app again once you've been out of it this many minutes; 0 = only when you
    /// walk away, the Mac locks, or you quit it.
    public var appRelockMinutes: Double = 0
    /// iMessage phone number or Apple ID email for intruder photos; empty = save photos only.
    public var alertTo: String = ""
    /// Require a live face (blink, screen-flash reflection, no phone held up) before the cover lifts or the Mac unlocks.
    public var liveness: Bool = true
    /// Unlock the lock screen when it sees you (needs `plock password` and Accessibility).
    public var faceUnlock: Bool = true
    /// Seconds the camera looks for you after a lock, and again each time the screen wakes or a key/trackpad is touched.
    /// The camera (and its light) is off the rest of the time.
    public var unlockLookSeconds: Double = 20
    /// "fast": you + no phone in view (lock screen) or you + screen-flash reflection (cover). "strict": also needs a blink.
    public var livenessMode: String = "fast"
    /// Cover check: "always" flashes red/blue every time. "suspicious" skips it on a strong match with no phone seen,
    /// but in testing a phone photo of you (score 0.80, edges out of frame) passed that way, so it's not the default.
    public var flashCheck: String = "always"
    /// Match score that counts as convincing enough to skip the flash (you typically score 0.8+).
    public var trustScore: Float = 0.5
    /// Glow brightness over the cover, 0...1 (1 = full-screen solid color).
    public var flashStrength: Float = 0.5
    /// Live-face check: "natural" waits for the small movement or blink you make anyway (default);
    /// "headturn" asks for a random head move; "glow" flashes the screen.
    public var liveCheck: String = "natural"
    /// Head movement (face widths, any direction) that counts as a live face in the natural check.
    public var naturalMove: Float = 0.035
    /// Lock screen also needs a blink (slower by a second or two, much harder to fool with a photo).
    public var lockScreenBlink: Bool = false
    /// Learn a new look of you after a confident live unlock (score at least this), at most every 10 minutes.
    public var learnScore: Float = 0.55
    /// The level picked in onboarding or Settings; editing a setting it controls makes it Custom.
    public var protectionLevel: ProtectionLevel = .custom
    /// Walking away locks the Mac for real instead of putting the cover up (Maximum does this everywhere).
    public var lockInsteadOfCover: Bool = false
    /// Saved places, recognized by Wi-Fi router or location; each sets how strict to be there.
    public var places: [Place] = []
    /// Mode anywhere that isn't a saved place (only applies once at least one place is saved).
    public var unknownPlaceMode: GuardMode = .normal
    /// Time windows that tighten the mode; the strictest of place and schedule wins.
    public var schedule: [ScheduleRule] = []
    /// No face in a frame this dark (0...1 average brightness) means "can't tell", not "gone".
    public var darkFrame: Float = 0.08
    /// Minimum flash response for a real face; tuned on a real face vs. a phone screen.
    public var flashMin: Float = 0.20

    /// Missing keys fall back to defaults, and the file is rewritten so new settings show up in it.
    public static func load() -> Config {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        var merged = (try? JSONSerialization.jsonObject(with: enc.encode(Config()))) as? [String: Any] ?? [:]
        if let d = try? Data(contentsOf: Paths.config), let file = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            merged.merge(file) { _, new in new }
        }
        let c = (try? JSONSerialization.data(withJSONObject: merged)).flatMap { try? JSONDecoder().decode(Config.self, from: $0) } ?? Config()
        c.save()
        return c
    }

    public func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: Paths.config)
    }
}

public func log(_ msg: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
    print(line, terminator: "")
    if let h = try? FileHandle(forWritingTo: Paths.log) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.data(using: .utf8)!.write(to: Paths.log)
    }
}

// MARK: - System state

func secondsIdle() -> Double {
    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
}

public func screenIsLocked() -> Bool {
    guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return (d["CGSSessionScreenIsLocked"] as? Bool) ?? false
}

public func lockScreen() {
    // Same call the Control Center "Lock Screen" item makes.
    if let h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW),
       let sym = dlsym(h, "SACLockScreenImmediate") {
        typealias Fn = @convention(c) () -> Int32
        let rc = unsafeBitCast(sym, to: Fn.self)()
        if rc == 0 { return }
        log("SACLockScreenImmediate returned \(rc), falling back to display sleep")
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    p.arguments = ["displaysleepnow"]
    try? p.run()
}


func fmt(_ f: Float) -> String { String(format: "%.2f", f) }
