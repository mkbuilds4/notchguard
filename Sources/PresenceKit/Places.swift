import AppKit
import CoreLocation
import CoreWLAN
import Foundation

// MARK: - Places and schedule

/// How hard NotchGuard guards right now.
public enum GuardMode: String, Codable, CaseIterable, Comparable {
    /// Longer wait before checking, cover only (never the real lock). Strangers still lock the Mac.
    case relaxed
    /// Your settings as they are.
    case normal
    /// Short wait, and walking away locks the Mac for real instead of putting the cover up.
    case strict

    var rank: Int { switch self { case .relaxed: 0; case .normal: 1; case .strict: 2 } }
    public static func < (a: GuardMode, b: GuardMode) -> Bool { a.rank < b.rank }
    public var title: String { switch self { case .relaxed: "Relaxed"; case .normal: "Normal"; case .strict: "Strict" } }
}

/// A place you've saved, recognized by its Wi-Fi router or by location.
public struct Place: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var name: String
    /// The router's hardware address. Anyone can name a hotspot "Home"; copying the router itself is much harder.
    public var bssid: String?
    public var latitude: Double?
    public var longitude: Double?
    /// Meters. Mac location comes from Wi-Fi positioning, so anything under ~100 m is noise.
    public var radius: Double = 150
    public var mode: GuardMode = .relaxed
}

/// A time window that changes the mode, e.g. weekdays 9-6 strict.
public struct ScheduleRule: Codable, Equatable, Identifiable {
    public var id = UUID()
    /// Calendar weekdays, 1 = Sunday ... 7 = Saturday.
    public var days: [Int] = [2, 3, 4, 5, 6]
    /// Minutes after midnight. An end before the start runs past midnight.
    public var start: Int = 9 * 60
    public var end: Int = 18 * 60
    public var mode: GuardMode = .strict

    func covers(_ date: Date) -> Bool {
        let cal = Calendar.current
        let c = cal.dateComponents([.weekday, .hour, .minute], from: date)
        let now = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        let today = c.weekday ?? 1
        if start <= end { return days.contains(today) && now >= start && now < end }
        // Overnight: the evening part belongs to today, the early-morning part to yesterday's rule.
        let yesterday = today == 1 ? 7 : today - 1
        return (days.contains(today) && now >= start) || (days.contains(yesterday) && now < end)
    }
}

/// Where the Mac is: the current Wi-Fi router plus a location fix refreshed on wake and every 10 minutes.
/// Both need Location Services (macOS hides the Wi-Fi network from apps without it).
@MainActor
public final class PlaceWatcher: NSObject, CLLocationManagerDelegate {
    public static let shared = PlaceWatcher()
    private let manager = CLLocationManager()
    public private(set) var location: CLLocation?
    private var timer: Timer?
    private var lastLogged = ""
    var onChange: (() -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    public var authorized: Bool {
        manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorized
    }
    public var denied: Bool { manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted }

    /// Asks for Location Services (once) and starts refreshing. Only runs when places or the schedule are in use.
    public func start() {
        guard timer == nil else { return }
        if manager.authorizationStatus == .notDetermined { manager.requestAlwaysAuthorization() }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        NSWorkspaceWake.observe { [weak self] in self?.refresh() }
    }

    public func refresh() { if authorized { manager.requestLocation() } }

    /// The router you're connected to, lowercased; nil off Wi-Fi or without Location Services.
    public var bssid: String? { CWWiFiClient.shared().interface()?.bssid()?.lowercased() }
    public var ssid: String? { CWWiFiClient.shared().interface()?.ssid() }

    public nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let l = locs.last else { return }
        MainActor.assumeIsolated { location = l; onChange?() }
    }
    public nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}
    public nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        MainActor.assumeIsolated { refresh(); onChange?() }
    }

    /// The saved place you're at: the same router, or within its radius. A location fix older than an hour
    /// doesn't count, so carrying the Mac somewhere new while it slept can't keep it relaxed.
    public func currentPlace(in places: [Place]) -> Place? {
        let router = bssid
        if let router, let p = places.first(where: { $0.bssid == router }) { return p }
        guard let loc = location, -loc.timestamp.timeIntervalSinceNow < 3600 else { return nil }
        return places.first { p in
            guard let lat = p.latitude, let lon = p.longitude else { return false }
            return loc.distance(from: CLLocation(latitude: lat, longitude: lon)) <= p.radius + loc.horizontalAccuracy
        }
    }

    /// The mode right now and why. The strictest of the place and any schedule window wins, so a schedule
    /// can tighten a relaxed place but nothing can loosen a strict one.
    public func mode(_ cfg: Config, at date: Date = Date()) -> (mode: GuardMode, reason: String) {
        var mode = GuardMode.normal
        var reason = "no places or schedule set"
        if !cfg.places.isEmpty {
            if let p = currentPlace(in: cfg.places) { mode = p.mode; reason = "at \(p.name)" }
            else { mode = cfg.unknownPlaceMode; reason = "not at a saved place" }
        }
        for r in cfg.schedule where r.covers(date) && r.mode > mode {
            mode = r.mode; reason = "schedule \(Self.time(r.start))-\(Self.time(r.end))"
        }
        let line = "\(mode.rawValue) (\(reason))"
        if line != lastLogged { lastLogged = line; log("mode: \(line)") }
        return (mode, reason)
    }

    static func time(_ minutes: Int) -> String { String(format: "%d:%02d", minutes / 60, minutes % 60) }
}

extension Config {
    /// These settings adjusted for a mode.
    func applying(_ mode: GuardMode) -> Config {
        var c = self
        switch mode {
        case .relaxed:
            c.idleGrace = max(idleGrace, 30)
            c.missesToLock = max(missesToLock, 3)
            c.coverMinutes = 0
            c.lockInsteadOfCover = false
        case .normal: break
        case .strict:
            c.idleGrace = min(idleGrace, 5)
        }
        return c
    }
}

/// Mac wake, for refreshing location.
enum NSWorkspaceWake {
    @MainActor static func observe(_ f: @escaping @MainActor () -> Void) {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { f() }
        }
    }
}
