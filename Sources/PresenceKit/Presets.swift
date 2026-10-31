import Foundation

/// One-tap protection levels for onboarding and Settings. Each sets the handful of settings people
/// actually care about; editing any of them by hand turns the level into Custom.
public enum ProtectionLevel: String, Codable, CaseIterable, Identifiable {
    case light, balanced, maximum, custom
    public var id: String { rawValue }
    /// Custom sits between levels; treat it as Balanced when deciding if a change loosens things.
    var rank: Int { switch self { case .light: 0; case .balanced, .custom: 1; case .maximum: 2 } }

    public var title: String {
        switch self {
        case .light: "Light"
        case .balanced: "Balanced"
        case .maximum: "Maximum"
        case .custom: "Custom"
        }
    }

    public var symbol: String {
        switch self {
        case .light: "leaf"
        case .balanced: "shield.lefthalf.filled"
        case .maximum: "lock.shield"
        case .custom: "slider.horizontal.3"
        }
    }

    public var summary: String {
        switch self {
        case .light: "For home. Waits 30 seconds, then only covers the screen."
        case .balanced: "For most people. Covers the screen after about 15 seconds, locks for real after 15 minutes."
        case .maximum: "For shared offices and travel. Locks for real as soon as you leave and asks for a head move and a blink."
        case .custom: "Your own settings."
        }
    }

    /// What it does, one line each, for the onboarding cards.
    public var details: [String] {
        switch self {
        case .light: ["Cover only, never the real lock", "No prompts to unlock", "Strangers still lock the Mac"]
        case .balanced: ["Cover first, real lock after 15 min", "No prompts to unlock", "Strangers lock the Mac right away"]
        case .maximum: ["Real lock within about 10 seconds", "Head move + blink to unlock", "Unknown places are Strict"]
        case .custom: []
        }
    }

    /// The settings this level controls. Everything else (alerts, locked apps, places) is left alone.
    func apply(to c: inout Config) {
        switch self {
        case .light:
            c.idleGrace = 30; c.missesToLock = 3; c.coverMinutes = 0
            c.liveCheck = "natural"; c.lockScreenBlink = false; c.appRelockMinutes = 0; c.unknownPlaceMode = .normal
            c.lockInsteadOfCover = false
        case .balanced:
            c.idleGrace = 10; c.missesToLock = 2; c.coverMinutes = 15
            c.liveCheck = "natural"; c.lockScreenBlink = false; c.appRelockMinutes = 0; c.unknownPlaceMode = .normal
            c.lockInsteadOfCover = false
        case .maximum:
            c.idleGrace = 5; c.missesToLock = 2; c.coverMinutes = 0
            c.liveCheck = "headturn"; c.lockScreenBlink = true; c.appRelockMinutes = 1; c.unknownPlaceMode = .strict
            c.lockInsteadOfCover = true
        case .custom: return
        }
        c.liveness = true
    }

    /// The level these settings match, or Custom.
    static func matching(_ c: Config) -> ProtectionLevel {
        for level in [ProtectionLevel.light, .balanced, .maximum] {
            var probe = c
            level.apply(to: &probe)
            probe.protectionLevel = c.protectionLevel
            if probe == c { return level }
        }
        return .custom
    }
}

extension Config {
    /// These settings with a protection level applied.
    public func with(_ level: ProtectionLevel) -> Config {
        var c = self
        level.apply(to: &c)
        c.protectionLevel = level
        return c
    }
}
