import AppKit
import AVFoundation
import QuartzCore

// MARK: - Lock-screen visibility

/// Private SkyLight window-server calls: the only known way to show a window on the real lock screen.
/// Adapted from Glance's NotchSkyLight (github.com/jonnyoo/glance, MIT), itself from Lakr233/SkyLightWindow (MIT).
/// `shared` is nil if the symbols are missing (a future macOS), and the HUD simply won't show while locked.
final class SkyLight {
    static let shared: SkyLight? = SkyLight()
    private let cid: Int32
    private let space: Int32
    private typealias AddFn = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32
    private typealias RemoveFn = @convention(c) (Int32, CFArray, CFArray) -> Int32
    private let add: AddFn
    private let remove: RemoveFn

    private init?() {
        typealias MainFn = @convention(c) () -> Int32
        typealias CreateFn = @convention(c) (Int32, Int32, Int32) -> Int32
        typealias LevelFn = @convention(c) (Int32, Int32, Int32) -> Int32
        typealias ShowFn = @convention(c) (Int32, CFArray) -> Int32
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW),
              let main = dlsym(h, "SLSMainConnectionID"), let create = dlsym(h, "SLSSpaceCreate"),
              let level = dlsym(h, "SLSSpaceSetAbsoluteLevel"), let show = dlsym(h, "SLSShowSpaces"),
              let add = dlsym(h, "SLSSpaceAddWindowsAndRemoveFromSpaces"), let remove = dlsym(h, "SLSRemoveWindowsFromSpaces")
        else { return nil }
        cid = unsafeBitCast(main, to: MainFn.self)()
        space = unsafeBitCast(create, to: CreateFn.self)(cid, 1, 0) // flag 1: otherwise Finder draws desktop icons into it
        _ = unsafeBitCast(level, to: LevelFn.self)(cid, space, 400) // Notification Center's lock-screen level
        _ = unsafeBitCast(show, to: ShowFn.self)(cid, [space] as CFArray)
        self.add = unsafeBitCast(add, to: AddFn.self)
        self.remove = unsafeBitCast(remove, to: RemoveFn.self)
    }

    func raise(_ w: NSWindow) { _ = add(cid, space, [w.windowNumber] as CFArray, 7) }
    func lower(_ w: NSWindow) { _ = remove(cid, [w.windowNumber] as CFArray, [space] as CFArray) }
}

// MARK: - Notch panel

/// A black shape that grows out of the camera notch (or a pill at the top on screens without one).
final class NotchPanel {
    let window: NSPanel
    let content = NSView()
    private let shape = CAShapeLayer()
    private let openSize: CGSize
    private let closedSize: CGSize
    private let frameSize: CGSize
    private var raised = false
    private(set) var isOpen = false

    init(openSize: CGSize) {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        let top = screen.safeAreaInsets.top
        if top > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            closedSize = CGSize(width: r.minX - l.maxX, height: top)
        } else {
            closedSize = CGSize(width: 120, height: 8)
        }
        self.openSize = CGSize(width: max(openSize.width, closedSize.width + 40), height: openSize.height)
        frameSize = CGSize(width: self.openSize.width + 40, height: self.openSize.height + 20)
        let origin = CGPoint(x: screen.frame.midX - frameSize.width / 2, y: screen.frame.maxY - frameSize.height)
        window = NSPanel(contentRect: NSRect(origin: origin, size: frameSize), styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.appearance = NSAppearance(named: .darkAqua)

        let root = NSView(frame: NSRect(origin: .zero, size: frameSize))
        root.wantsLayer = true
        shape.fillColor = NSColor.black.cgColor
        shape.path = path(closedSize)
        root.layer?.addSublayer(shape)
        content.frame = NSRect(x: (frameSize.width - self.openSize.width) / 2, y: frameSize.height - self.openSize.height,
                               width: self.openSize.width, height: self.openSize.height)
        content.alphaValue = 0
        root.addSubview(content)
        window.contentView = root
    }

    /// Bottom-rounded body with small outward flares where it meets the top edge, like the hardware notch.
    private func path(_ s: CGSize) -> CGPath {
        let W = frameSize.width, H = frameSize.height
        let left = (W - s.width) / 2, right = left + s.width, bottom = H - s.height
        let r = min(s.height / 2, s.width < 200 ? 10 : 28), f: CGFloat = 8
        let p = CGMutablePath()
        p.move(to: CGPoint(x: left - f, y: H))
        p.addQuadCurve(to: CGPoint(x: left, y: H - f), control: CGPoint(x: left, y: H))
        p.addLine(to: CGPoint(x: left, y: bottom + r))
        p.addQuadCurve(to: CGPoint(x: left + r, y: bottom), control: CGPoint(x: left, y: bottom))
        p.addLine(to: CGPoint(x: right - r, y: bottom))
        p.addQuadCurve(to: CGPoint(x: right, y: bottom + r), control: CGPoint(x: right, y: bottom))
        p.addLine(to: CGPoint(x: right, y: H - f))
        p.addQuadCurve(to: CGPoint(x: right + f, y: H), control: CGPoint(x: right, y: H))
        p.closeSubpath()
        return p
    }

    private func animateShape(to size: CGSize, duration: Double) {
        let new = path(size)
        let a = CASpringAnimation(keyPath: "path")
        a.fromValue = shape.presentation()?.path ?? shape.path
        a.toValue = new
        a.damping = 18; a.stiffness = 220; a.mass = 1
        a.duration = duration
        shape.path = new
        shape.add(a, forKey: "path")
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        window.orderFrontRegardless()
        if screenIsLocked(), let sky = SkyLight.shared, !raised { sky.raise(window); raised = true }
        animateShape(to: openSize, duration: 0.6)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            content.animator().alphaValue = 1
        }
    }

    func close(after delay: Double = 0, completion: (() -> Void)? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            guard isOpen else { completion?(); return }
            isOpen = false
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; content.animator().alphaValue = 0 }
            animateShape(to: closedSize, duration: 0.45)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [self] in
                guard !isOpen else { return }
                if raised { SkyLight.shared?.lower(window); raised = false }
                window.orderOut(nil)
                completion?()
            }
        }
    }
}

// MARK: - Face ID HUD

public enum HUDState {
    case scanning(String), success(String), failure(String)
}

/// The host's presenter, if it draws the HUD and enrollment itself (NotchNerd); nil = our own NotchPanel.
private func hostPresenter() -> GuardPresenter? {
    MainActor.assumeIsolated { PresenceGuard.shared.presenter }
}

/// Notch panel with the Face ID glyph: pulses while looking, green on success, red and a shake on failure.
final class FaceHUD {
    typealias State = HUDState

    private let panel = NotchPanel(openSize: CGSize(width: 220, height: 170))
    private let glyph = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init() {
        let c = panel.content
        let symbol = NSImage(systemSymbolName: "faceid", accessibilityDescription: "Face ID")?
            .withSymbolConfiguration(.init(pointSize: 58, weight: .light))
        glyph.image = symbol
        glyph.contentTintColor = .white
        glyph.frame = NSRect(x: (c.bounds.width - 76) / 2, y: 44, width: 76, height: 76)
        glyph.wantsLayer = true
        label.frame = NSRect(x: 10, y: 14, width: c.bounds.width - 20, height: 20)
        label.alignment = .center
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.75)
        c.addSubview(glyph)
        c.addSubview(label)
    }

    var isShown: Bool { hostPresenter() == nil && panel.isOpen }

    func show(_ state: State) {
        if let host = hostPresenter() { MainActor.assumeIsolated { host.showHUD(state) }; return }
        switch state {
        case .scanning(let text):
            glyph.removeAllSymbolEffects()
            glyph.contentTintColor = .white
            label.stringValue = text
            glyph.addSymbolEffect(.pulse, options: .repeating)
        case .success(let text):
            glyph.removeAllSymbolEffects()
            glyph.contentTintColor = .systemGreen
            label.stringValue = text
            glyph.addSymbolEffect(.bounce, options: .nonRepeating)
        case .failure(let text):
            glyph.removeAllSymbolEffects()
            glyph.contentTintColor = .systemRed
            label.stringValue = text
            let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
            shake.values = [0, -10, 10, -8, 8, -4, 4, 0]
            shake.duration = 0.45
            glyph.layer?.add(shake, forKey: "shake")
        }
        panel.open()
    }

    func hide(after delay: Double = 0) {
        if let host = hostPresenter() { MainActor.assumeIsolated { host.hideHUD(after: delay) }; return }
        panel.close(after: delay) { [glyph] in glyph.removeAllSymbolEffects() }
    }
}

// MARK: - Notch enrollment

/// Face ID-style setup: a round mirror of you under the notch, ringed by ticks that fill in
/// as you tilt toward each of eight directions.
final class NotchEnroller {
    /// Called with true when a profile was saved. Defaults to quitting (the `plock enroll` process).
    var onFinish: (Bool) -> Void = { _ in NSApp.terminate(nil) }
    static let directions = ["up", "top right", "right", "bottom right", "down", "bottom left", "left", "top left"]
    let perDirection = 4
    let centerTarget = 10

    private let matcher: FaceMatcher
    private let camera: Camera
    private let panel = NotchPanel(openSize: CGSize(width: 320, height: 380))
    private let label = NSTextField(labelWithString: "Look straight at the camera")
    private var ticks: [CAShapeLayer] = []
    private let tickCount = 64

    private var center: [[Float]] = []
    private var bySector = [[[Float]]](repeating: [], count: 8)
    private var neutral: CGPoint?
    private var neutralSamples: [CGPoint] = []
    private var busy = false
    private var last = Date.distantPast
    private var finished = false

    init(matcher: FaceMatcher, camera: Camera) {
        self.matcher = matcher
        self.camera = camera
        let c = panel.content
        c.wantsLayer = true
        let d: CGFloat = 200
        let circle = CGRect(x: (c.bounds.width - d) / 2, y: 110, width: d, height: d)

        let preview = AVCaptureVideoPreviewLayer(session: camera.session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = circle
        preview.cornerRadius = d / 2
        preview.masksToBounds = true
        preview.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1)) // mirror
        c.layer?.addSublayer(preview)

        let mid = CGPoint(x: circle.midX, y: circle.midY)
        for i in 0..<tickCount {
            // Angle 0 = up, clockwise, so tick sectors line up with `directions`.
            let a = CGFloat(i) / CGFloat(tickCount) * 2 * .pi
            let dir = CGPoint(x: sin(a), y: cos(a))
            let p = CGMutablePath()
            p.move(to: CGPoint(x: mid.x + dir.x * (d / 2 + 10), y: mid.y + dir.y * (d / 2 + 10)))
            p.addLine(to: CGPoint(x: mid.x + dir.x * (d / 2 + 22), y: mid.y + dir.y * (d / 2 + 22)))
            let t = CAShapeLayer()
            t.path = p
            t.strokeColor = NSColor.white.withAlphaComponent(0.25).cgColor
            t.lineWidth = 3
            t.lineCap = .round
            c.layer?.addSublayer(t)
            ticks.append(t)
        }

        label.frame = NSRect(x: 10, y: 40, width: c.bounds.width - 20, height: 44)
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .white
        c.addSubview(label)
    }

    func begin() {
        if let host = hostPresenter() { MainActor.assumeIsolated { host.enrollmentBegan(session: camera.session) } }
        else { panel.open() }
        camera.start { [weak self] pb in self?.frame(pb) }
    }

    private func sector(forTick i: Int) -> Int { Int((Double(i) + Double(tickCount) / 16) / Double(tickCount) * 8) % 8 }

    private func frame(_ pb: CVPixelBuffer) {
        guard !busy, !finished, Date().timeIntervalSince(last) > 0.12 else { return }
        busy = true
        defer { busy = false }
        let faces = matcher.faces(in: pb)
        guard faces.count == 1, let pose = matcher.pose(pb) else {
            DispatchQueue.main.async { [self] in if !finished { setPrompt(faces.count > 1 ? "Only you in frame, please" : "Move your face into the circle") } }
            return
        }
        last = Date()
        let emb = faces[0].embedding
        DispatchQueue.main.async { [self] in handle(emb, pose: pose) }
    }

    private func handle(_ emb: [Float], pose: CGPoint) {
        guard !finished else { return }
        if center.count < centerTarget {
            center.append(emb)
            neutralSamples.append(pose)
            if center.count == centerTarget {
                neutral = CGPoint(x: neutralSamples.map(\.x).reduce(0, +) / CGFloat(centerTarget),
                                  y: neutralSamples.map(\.y).reduce(0, +) / CGFloat(centerTarget))
            }
            setPrompt(center.count < centerTarget ? "Look straight at the camera" : prompt())
            return
        }
        guard let neutral else { return }
        let v = CGPoint(x: pose.x - neutral.x, y: pose.y - neutral.y)
        if hypot(v.x, v.y) > 0.07 {
            // 0 = up, clockwise (screen-space, mirrored like the preview)
            var angle = atan2(v.x, v.y)
            if angle < 0 { angle += 2 * .pi }
            let s = Int((angle / (2 * .pi) * 8).rounded()) % 8
            if bySector[s].count < perDirection {
                bySector[s].append(emb)
                light(sector: s)
            }
        }
        if bySector.allSatisfy({ $0.count >= perDirection }) { finish() } else { setPrompt(prompt()) }
    }

    private func light(sector s: Int) {
        let filled = CGFloat(bySector[s].count) / CGFloat(perDirection)
        let mine = ticks.indices.filter { sector(forTick: $0) == s }
        for (k, i) in mine.enumerated() where CGFloat(k + 1) / CGFloat(mine.count) <= filled + 0.01 {
            ticks[i].strokeColor = NSColor.systemGreen.cgColor
        }
    }

    private func prompt() -> String {
        guard let next = bySector.indices.first(where: { bySector[$0].count < perDirection }) else { return "" }
        return "Tilt your head to the \(Self.directions[next])"
    }

    /// Updates our label, or tells the host presenter (prompt, 8 sector fills 0...1, straight-on progress 0...1).
    private func setPrompt(_ text: String) {
        label.stringValue = text
        guard let host = hostPresenter() else { return }
        let fill = bySector.map { min(1, Double($0.count) / Double(perDirection)) }
        let centerProgress = min(1, Double(center.count) / Double(centerTarget))
        MainActor.assumeIsolated { host.enrollmentUpdated(prompt: text, sectorFill: fill, centerProgress: centerProgress) }
    }

    /// Stops without saving (the host's cancel button).
    func cancel() {
        guard !finished else { return }
        finished = true
        camera.stop()
        end(ok: false, message: "Setup cancelled")
    }

    private func end(ok: Bool, message: String) {
        if let host = hostPresenter() {
            MainActor.assumeIsolated { host.enrollmentEnded(ok: ok, message: message) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [onFinish] in onFinish(ok) }
        } else {
            label.stringValue = message
            panel.close(after: 1.6) { [onFinish] in onFinish(ok) }
        }
    }

    private func finish() {
        finished = true
        camera.stop()
        let samples = center + bySector.flatMap { $0 }
        do {
            try Profile(samples: samples, createdAt: Date()).save()
            log("enrolled \(samples.count) samples (\(centerTarget) straight-on + \(perDirection) in each of 8 directions)")
            ticks.forEach { $0.strokeColor = NSColor.systemGreen.cgColor }
            end(ok: true, message: "Face set up")
        } catch {
            end(ok: false, message: "Couldn't save: \(error.localizedDescription)")
        }
    }
}
