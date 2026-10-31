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
}
