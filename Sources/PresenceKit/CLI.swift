import AppKit
import AVFoundation
import CoreGraphics
import Foundation

/// The `plock` subcommands (enroll, check, password, live-test, hud-test, cover-test, lock-test, run).
@MainActor
public enum PresenceCLI {
    public nonisolated static let commands: Set<String> = ["install-model", "run", "enroll", "check", "password", "live-test", "hud-test", "cover-test", "lock-test", "onboarding"]
    public nonisolated static let interactive: Set<String> = ["enroll", "password", "onboarding"]
    private static var keep: [AnyObject] = []

    public static func run(_ command: String, args: [String]) async {
        if command == "onboarding" {
            // Set PLOCK_HOME to a scratch folder to run it as a brand-new user without touching your setup.
            let w = OnboardingWindow()
            w.onFinish = { log("onboarding finished"); exit(0) }
            keep.append(w)
            w.show()
            if let dir = ProcessInfo.processInfo.environment["PLOCK_SNAPSHOTS"] {
                await w.snapshotSteps(to: URL(fileURLWithPath: dir))
                log("onboarding snapshots saved to \(dir)")
                exit(0)
            }
            return
        }
        if command == "install-model" {
            do {
                try await PresenceGuard.shared.installModel { p in if Int(p * 100) % 25 == 0 { log("model download \(Int(p * 100))%") } }
                exit(0)
            } catch {
                log("model install failed: \(error.localizedDescription)")
                exit(1)
            }
        }
        let needsCamera = !["cover-test", "lock-test", "password", "hud-test"].contains(command)
        let cameraOK = needsCamera ? await Camera.authorize() : true
        guard cameraOK else {
            log("camera access denied: allow NotchGuard in System Settings > Privacy & Security > Camera")
            exit(2)
        }
        do {
            switch command {
            case "enroll":
                let e = NotchEnroller(matcher: try FaceMatcher(), camera: try Camera(preset: .high))
                keep.append(e)
                e.begin()

            case "check":
                guard let p = Profile.load() else { log("no profile, run enroll first"); exit(1) }
                let m = try Monitor(profile: p)
                m.verbose = true
                let start = Date()
                if let (r, frames) = await m.burstLook() {
                    let verdict = r.me ? "YOU" : r.stranger ? "STRANGER" : "not you"
                    log("check: \(r.faces) face(s), best score \(fmt(r.best)) (threshold \(fmt(m.cfg.threshold))) -> \(verdict) in \(Int(Date().timeIntervalSince(start) * 1000))ms")
                    if args.contains("--alert") {
                        let photos = Alert.save(Array(frames.prefix(1)))
                        if m.cfg.alertTo.isEmpty { log("alertTo not set in config.json") }
                        else { Alert.send(to: m.cfg.alertTo, text: "NotchGuard test alert", photos: photos) }
                        try? await Task.sleep(for: .seconds(15)) // let osascript finish
                    }
                } else {
                    log("check: camera unavailable")
                }
                exit(0)

            case "password":
                let s = PasswordSetup()
                keep.append(s)
                s.begin()

            case "live-test":
                guard let p = Profile.load() else { log("no profile, run enroll first"); exit(1) }
                let m = try Monitor(profile: p)
                if let s = args.dropFirst().first.flatMap(Float.init) { m.cfg.flashStrength = s }
                let lockMode = args.contains("lock")
                if lockMode { m.startFrames() } else { m.enterCover() }
                try? await Task.sleep(for: .seconds(1.5))
                let start = Date()
                let (verdict, ev) = await m.checkLive(seconds: 8, cover: lockMode ? nil : m.cover)
                log("live-test took \(Int(Date().timeIntervalSince(start) * 1000))ms")
                if let f = m.newestFrame() { log("live-test snapshot: \(Alert.save([f]).first?.path ?? "-")") }
                log("live-test @\(fmt(m.cfg.flashStrength)): \(verdict) (\(ev.summary)) red \(ev.redTint.map(fmt)) blue \(ev.blueTint.map(fmt))")
                m.exitCover("live-test done")
                try? await Task.sleep(for: .seconds(0.5))
                exit(0)

            case "hud-test":
                let h = FaceHUD()
                h.show(.scanning("Looking for you"))
                try? await Task.sleep(for: .seconds(2.5))
                h.show(.success("Welcome back"))
                try? await Task.sleep(for: .seconds(1.5))
                h.show(.failure("Not a real face"))
                try? await Task.sleep(for: .seconds(1.5))
                h.hide()
                try? await Task.sleep(for: .seconds(0.8))
                exit(0)

            case "cover-test":
                let c = Cover()
                c.show(lockAfter: nil)
                try? await Task.sleep(for: .seconds(Double(args.dropFirst().first ?? "8") ?? 8))
                c.hide()
                try? await Task.sleep(for: .seconds(0.5))
                exit(0)

            case "lock-test":
                lockScreen(); exit(0)

            default:
                guard let p = Profile.load() else { log("no profile, run enroll first"); exit(1) }
                try await Monitor(profile: p).run()
            }
        } catch {
            log("error: \(error.localizedDescription)")
            exit(1)
        }
    }
}
