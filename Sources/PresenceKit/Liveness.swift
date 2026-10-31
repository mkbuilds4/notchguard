import AppKit
import CoreVideo
import Foundation

/// Evidence gathered over one live-face check.
struct Liveness {
    var eyeOpen: [Float] = []
    var eyeTimes: [Date] = []
    var bestEmbedding: [Float]?
    var redTint: [Float] = []
    var blueTint: [Float] = []
    var deviceHits = 0
    var meSeen = false
    var best: Float = -1
    var flashed = false
    var faceFrames = 0

    /// Eyes dipped well below their usual openness and then reopened. A photo can't do that.
    /// Open, then closed, then open again, all within ~0.7s: a real blink, not a wobble or a dropped frame.
    var blinked: Bool {
        guard eyeOpen.count >= 6, eyeTimes.count == eyeOpen.count else { return false }
        let open = eyeOpen.sorted()[Int(Double(eyeOpen.count) * 0.8)]
        guard open > 0 else { return false }
        for i in eyeOpen.indices where eyeOpen[i] < open * 0.55 {
            let t = eyeTimes[i]
            let before = eyeOpen.indices.contains { j in j < i && t.timeIntervalSince(eyeTimes[j]) <= 0.7 && eyeOpen[j] > open * 0.85 }
            let after = eyeOpen.indices.contains { j in j > i && eyeTimes[j].timeIntervalSince(t) <= 0.7 && eyeOpen[j] > open * 0.85 }
            if before && after { return true }
        }
        return false
    }

    /// How much more red the face got under the red flash than under the blue one.
    /// A real face close to the screen reflects it; a phone screen mostly shows its own light.
    var flash: Float? {
        guard redTint.count >= 2, blueTint.count >= 2 else { return nil }
        return redTint.reduce(0, +) / Float(redTint.count) - blueTint.reduce(0, +) / Float(blueTint.count)
    }

    var summary: String {
        "score \(fmt(best)), blink \(blinked ? "yes" : "no"), flash\(flashed ? "" : " skipped") \(flash.map(fmt) ?? "n/a"), device \(deviceHits), me \(meSeen ? "yes" : "no"), \(faceFrames) face frames"
    }
}

enum LiveVerdict {
    case live
    case spoof(String)
    case inconclusive
}

extension Monitor {
    /// Watches the (already running) camera for up to `seconds`. With `cover`, first floods the screen
    /// red/blue/red/blue to test for a reflecting face. Returns as soon as the outcome is clear.
    /// Fast mode (default) passes on you + flash response (cover) or you + no phone in view (lock screen);
    /// strict mode also waits for a blink.
    func checkLive(seconds: Double, cover: Cover?) async -> (LiveVerdict, Liveness) {
        if cfg.liveCheck == "headturn" { return await headTurnCheck(seconds: seconds, cover: cover) }
        if cfg.liveCheck == "natural" { return await naturalCheck(seconds: seconds, cover: cover) }
        let strict = cfg.livenessMode == "strict"
        var ev = Liveness()
        let start = Date()
        var lastIdentity = Date.distantPast
        var lastDevice = Date.distantPast

        func sample(phase: Bool?) {
            guard let frame = newestFrame(), let p = matcher.probe(frame) else { return }
            ev.faceFrames += 1
            ev.eyeOpen.append(p.eyeOpen)
            ev.eyeTimes.append(Date())
            if let red = phase { red ? ev.redTint.append(p.tint) : ev.blueTint.append(p.tint) }
            if Date().timeIntervalSince(lastDevice) > 0.3 {
                lastDevice = Date()
                if matcher.deviceAround(frame, face: p.box) { ev.deviceHits += 1 }
            }
            if Date().timeIntervalSince(lastIdentity) > 0.5 {
                lastIdentity = Date()
                let l = look(frame)
                if l.me { ev.meSeen = true }
                if l.best > ev.best { ev.bestEmbedding = l.bestEmbedding }
                ev.best = max(ev.best, l.best)
            }
        }

        if let cover {
            // Passive look first: a strong match with no phone in view lifts the cover without the flash.
            let passiveStart = Date()
            while cfg.flashCheck != "always" && Date().timeIntervalSince(passiveStart) < 0.7 {
                try? await Task.sleep(for: .milliseconds(80))
                sample(phase: nil)
            }
            if cfg.flashCheck != "always", ev.meSeen, ev.best >= cfg.trustScore, ev.deviceHits == 0, ev.faceFrames >= 5,
               !strict || ev.blinked {
                return (.live, ev)
            }
            ev.flashed = true
            cover.setMessage("Checking it's you…")
            // Warm vs. cool glow; the check only needs the face's red/blue balance to follow the screen.
            let warm = NSColor(red: 1, green: 0.55, blue: 0.2, alpha: 1)
            let cool = NSColor(red: 0.15, green: 0.6, blue: 1, alpha: 1)
            for (color, isRed) in [(warm, true), (cool, false), (warm, true), (cool, false)] {
                cover.setFlash(color, strength: cfg.flashStrength)
                let phaseStart = Date()
                while Date().timeIntervalSince(phaseStart) < 0.25 {
                    try? await Task.sleep(for: .milliseconds(35))
                    // Skip the first frames of each phase: the camera lags the screen.
                    sample(phase: Date().timeIntervalSince(phaseStart) > 0.12 ? isRed : nil)
                }
            }
            cover.setFlash(nil, fade: 0.25)
        }

        lastIdentity = .distantPast // force an identity read on the first frame
        while Date().timeIntervalSince(start) < seconds {
            if ev.deviceHits >= 3 { return (.spoof("phone or tablet held up"), ev) }
            if let f = ev.flash, f < cfg.flashMin, ev.meSeen { return (.spoof("no reflection from the screen flash"), ev) }
            let elapsed = Date().timeIntervalSince(start)
            let steady = cover != nil ? ev.flash != nil : (ev.faceFrames >= 6 && elapsed >= 0.5)
            let needBlink = strict || (cover == nil && cfg.lockScreenBlink)
            if ev.meSeen && steady && (ev.blinked || !needBlink) { return (.live, ev) }
            if needBlink && ev.meSeen && !ev.blinked && elapsed > 1 { cover?.setMessage("Blink to unlock"); hud.show(.scanning("Blink to unlock")) }
            try? await Task.sleep(for: .milliseconds(cover == nil ? 50 : 80))
            sample(phase: nil)
        }
        return (.inconclusive, ev)
    }

    // MARK: natural movement

    /// No prompt: a live head never holds perfectly still, so it waits for the small movement you make anyway
    /// (any direction) or a blink. A photo or a phone screen keeps the nose fixed against the eyes however the
    /// hand moves it, so it never shows that shift. Only after ~2.5s of stillness does it ask for "any" movement.
    func naturalCheck(seconds: Double, cover: Cover?) async -> (LiveVerdict, Liveness) {
        var ev = Liveness()
        let start = Date()
        var lastIdentity = Date.distantPast
        var lastDevice = Date.distantPast
        var poses: [CGPoint] = []
        var nudged = false
        let needBlink = cfg.livenessMode == "strict" || (cover == nil && cfg.lockScreenBlink)

        while Date().timeIntervalSince(start) < seconds {
            try? await Task.sleep(for: .milliseconds(50))
            guard let frame = newestFrame(), let p = matcher.probe(frame) else { continue }
            ev.faceFrames += 1
            ev.eyeOpen.append(p.eyeOpen)
            ev.eyeTimes.append(Date())
            if Date().timeIntervalSince(lastDevice) > 0.3 {
                lastDevice = Date()
                if matcher.deviceAround(frame, face: p.box) { ev.deviceHits += 1 }
            }
            if ev.deviceHits >= 3 { return (.spoof("phone or tablet held up"), ev) }
            if Date().timeIntervalSince(lastIdentity) > 0.4 {
                lastIdentity = Date()
                let l = look(frame)
                if l.me { ev.meSeen = true }
                if l.best > ev.best { ev.bestEmbedding = l.bestEmbedding }
                ev.best = max(ev.best, l.best)
            }
            if let pose = matcher.pose(frame) { poses.append(pose) }
            guard ev.meSeen, poses.count >= 4 else { continue }

            let xs = poses.map(\.x), ys = poses.map(\.y)
            let moved = max(xs.max()! - xs.min()!, ys.max()! - ys.min()!)
            let lively = moved >= CGFloat(cfg.naturalMove) || ev.blinked
            if lively && (!needBlink || ev.blinked) {
                log("natural: ok (moved \(fmt(Float(moved))) face widths, blink \(ev.blinked ? "yes" : "no"))")
                if nudged { cover?.setMessage(nil) }
                return (.live, ev)
            }
            if !nudged && Date().timeIntervalSince(start) > 2.5 {
                nudged = true
                let msg = needBlink && moved >= CGFloat(cfg.naturalMove) ? "Blink to unlock" : "Move your head a little"
                hud.show(.scanning(msg)); cover?.setMessage(msg)
            }
        }
        let xs = poses.map(\.x), ys = poses.map(\.y)
        let moved = poses.isEmpty ? 0 : max(xs.max()! - xs.min()!, ys.max()! - ys.min()!)
        log("natural: not live yet (moved \(fmt(Float(moved))), \(ev.summary))")
        cover?.setMessage(nil)
        return (.inconclusive, ev)
    }

    // MARK: head-turn challenge

    enum TurnDirection: CaseIterable {
        case left, right, up, down
        var prompt: String {
            switch self {
            case .left: "Turn your head left"
            case .right: "Turn your head right"
            case .up: "Look up"
            case .down: "Look down"
            }
        }
        /// How far the head moved this way, from a pose delta (x = your right, y = up, in face widths).
        func along(_ d: CGPoint) -> CGFloat {
            switch self {
            case .left: -d.x
            case .right: d.x
            case .up: d.y
            case .down: -d.y
            }
        }
        func across(_ d: CGPoint) -> CGFloat { self == .left || self == .right ? abs(d.y) : abs(d.x) }
        /// Pitch moves the nose less than yaw does.
        var needed: CGFloat { self == .left || self == .right ? 0.07 : 0.05 }
    }

    /// Asks for one random head move and checks the face really turns that way. A photo can't follow it
    /// and a recording can't know which move is coming. Phone-outline detection still runs alongside.
    func headTurnCheck(seconds: Double, cover: Cover?) async -> (LiveVerdict, Liveness) {
        var ev = Liveness()
        let start = Date()
        var lastIdentity = Date.distantPast
        var lastDevice = Date.distantPast
        var poses: [CGPoint] = []

        /// One frame: face probe, phone check, identity every 0.4s, head pose.
        func sample() -> CGPoint? {
            guard let frame = newestFrame(), let p = matcher.probe(frame) else { return nil }
            ev.faceFrames += 1
            ev.eyeOpen.append(p.eyeOpen)
            ev.eyeTimes.append(Date())
            if Date().timeIntervalSince(lastDevice) > 0.3 {
                lastDevice = Date()
                if matcher.deviceAround(frame, face: p.box) { ev.deviceHits += 1 }
            }
            if Date().timeIntervalSince(lastIdentity) > 0.4 {
                lastIdentity = Date()
                let l = look(frame)
                if l.me { ev.meSeen = true }
                if l.best > ev.best { ev.bestEmbedding = l.bestEmbedding }
                ev.best = max(ev.best, l.best)
            }
            return matcher.pose(frame)
        }

        // 1. Straight-on baseline, with your identity confirmed.
        while Date().timeIntervalSince(start) < 1.5 {
            try? await Task.sleep(for: .milliseconds(60))
            if let pose = sample() { poses.append(pose) }
            if ev.deviceHits >= 3 { return (.spoof("phone or tablet held up"), ev) }
            if ev.meSeen && poses.count >= 5 { break }
        }
        guard ev.meSeen, poses.count >= 3 else { return (.inconclusive, ev) }
        let xs = poses.map(\.x).sorted(), ys = poses.map(\.y).sorted()
        let base = CGPoint(x: xs[xs.count / 2], y: ys[ys.count / 2])

        // 2. The challenge.
        let dir = TurnDirection.allCases.randomElement()!
        hud.show(.scanning(dir.prompt))
        cover?.setMessage(dir.prompt)
        let asked = Date()
        var stillMe = false
        while Date().timeIntervalSince(asked) < min(4, max(2, seconds - Date().timeIntervalSince(start))) {
            try? await Task.sleep(for: .milliseconds(50))
            guard let pose = sample() else { continue }
            if ev.deviceHits >= 3 { return (.spoof("phone or tablet held up"), ev) }
            if ev.meSeen { stillMe = true }
            let d = CGPoint(x: pose.x - base.x, y: pose.y - base.y)
            if dir.along(d) > dir.needed && dir.along(d) > dir.across(d) {
                let needBlink = cfg.livenessMode == "strict" || (cover == nil && cfg.lockScreenBlink)
                if needBlink && !ev.blinked { continue }
                log("head-turn: \(dir) ok (moved \(fmt(Float(dir.along(d)))) face widths)")
                return stillMe ? (.live, ev) : (.inconclusive, ev)
            }
        }
        log("head-turn: \(dir) not seen")
        cover?.setMessage(nil)
        return (.inconclusive, ev)
    }
}
