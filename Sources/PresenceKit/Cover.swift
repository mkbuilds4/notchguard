import AppKit
import QuartzCore

/// Short-break cover: frosted blur of the desktop under a dark tinted wash, a drifting glow,
/// the time, and a countdown to the real lock. One window per screen, above everything.
final class Cover {
    private var windows: [NSWindow] = []
    private var timer: Timer?
    private var shownAt = Date()
    private var deadline: Date?
    private var clocks: [NSTextField] = []
    private var dates: [NSTextField] = []
    private var countdowns: [NSTextField] = []
    private var hints: [NSTextField] = []
    private var flashes: [CALayer] = []
    private let defaultHint = "Sit back down and this clears on its own"

    var isShown: Bool { !windows.isEmpty }
    var since: Date { shownAt }

    /// `lockAfter` nil = stay up until you're back (or an intruder trips the real lock).
    func show(lockAfter: TimeInterval?) {
        guard !isShown else { return }
        shownAt = Date()
        deadline = lockAfter.map { shownAt.addingTimeInterval($0) }
        for screen in NSScreen.screens { windows.append(makeWindow(screen)) }
        NSApp.activate(ignoringOtherApps: true)
        windows.forEach { $0.orderFrontRegardless() }
        windows.first?.makeKey()
        windows.forEach { w in
            w.alphaValue = 0
            NSAnimationContext.runAnimationGroup { $0.duration = 0.6; w.animator().alphaValue = 1 }
        }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    func hide(animated: Bool = true) {
        guard isShown else { return }
        timer?.invalidate(); timer = nil
        let closing = windows
        windows = []; clocks = []; dates = []; countdowns = []; hints = []; flashes = []
        guard animated else { closing.forEach { $0.orderOut(nil) }; return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            closing.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: { closing.forEach { $0.orderOut(nil) } })
    }

    /// Floods the screen with a color (lighting your face for the liveness check); nil clears it.
    /// `strength` 0...1 is the layer's opacity over the dark cover; changes fade over `fade` seconds.
    func setFlash(_ color: NSColor?, strength: Float = 1, fade: Double = 0.08) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(fade)
        flashes.forEach { if let color { $0.backgroundColor = color.cgColor }; $0.opacity = color == nil ? 0 : strength }
        CATransaction.commit()
    }

    func setMessage(_ text: String?) {
        hints.forEach { $0.stringValue = text ?? defaultHint }
    }

    private func tick() {
        let now = Date()
        let time = now.formatted(date: .omitted, time: .shortened)
        let day = now.formatted(.dateTime.weekday(.wide).month(.wide).day())
        let away = Int(now.timeIntervalSince(shownAt))
        _ = away
        // Only a real-lock countdown is worth showing; with no limit the line stays empty.
        let status = deadline.map { "Locks in \(mmss(max(0, Int($0.timeIntervalSince(now)))))" } ?? ""
        clocks.forEach { $0.stringValue = time }
        dates.forEach { $0.stringValue = day }
        countdowns.forEach { $0.stringValue = status }
    }

    private func mmss(_ s: Int) -> String { String(format: "%d:%02d", s / 60, s % 60) }

    private func makeWindow(_ screen: NSScreen) -> NSWindow {
        let w = CoverWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.setFrame(screen.frame, display: false)
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.appearance = NSAppearance(named: .darkAqua)

        let bounds = NSRect(origin: .zero, size: screen.frame.size)
        let blur = NSVisualEffectView(frame: bounds)
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]

        let art = NSView(frame: bounds)
        art.wantsLayer = true
        art.autoresizingMask = [.width, .height]
        let root = art.layer!

        // Dark wash: the blur alone can leave large text legible.
        let wash = CAGradientLayer()
        wash.frame = bounds
        wash.colors = [NSColor(red: 0.04, green: 0.05, blue: 0.09, alpha: 0.80).cgColor,
                       NSColor(red: 0.07, green: 0.06, blue: 0.13, alpha: 0.86).cgColor]
        wash.startPoint = CGPoint(x: 0, y: 1); wash.endPoint = CGPoint(x: 1, y: 0)
        root.addSublayer(wash)

        // Two slow-drifting glows.
        for (i, color) in [NSColor(red: 0.20, green: 0.45, blue: 0.95, alpha: 0.35),
                           NSColor(red: 0.85, green: 0.35, blue: 0.65, alpha: 0.25)].enumerated() {
            let d = max(bounds.width, bounds.height) * 0.7
            let glow = CAGradientLayer()
            glow.type = .radial
            glow.colors = [color.cgColor, color.withAlphaComponent(0).cgColor]
            glow.startPoint = CGPoint(x: 0.5, y: 0.5); glow.endPoint = CGPoint(x: 1, y: 1)
            glow.bounds = CGRect(x: 0, y: 0, width: d, height: d)
            let a = CGPoint(x: bounds.width * (i == 0 ? 0.25 : 0.8), y: bounds.height * (i == 0 ? 0.7 : 0.25))
            let b = CGPoint(x: bounds.width * (i == 0 ? 0.45 : 0.6), y: bounds.height * (i == 0 ? 0.45 : 0.5))
            glow.position = a
            let drift = CABasicAnimation(keyPath: "position")
            drift.fromValue = NSValue(point: a); drift.toValue = NSValue(point: b)
            drift.duration = i == 0 ? 23 : 31
            drift.autoreverses = true; drift.repeatCount = .infinity
            drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            glow.add(drift, forKey: "drift")
            root.addSublayer(glow)
        }

        func label(_ size: CGFloat, _ weight: NSFont.Weight, alpha: CGFloat) -> NSTextField {
            let l = NSTextField(labelWithString: "")
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            l.font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
            l.textColor = NSColor.white.withAlphaComponent(alpha)
            l.alignment = .center
            l.translatesAutoresizingMaskIntoConstraints = false
            return l
        }
        let clock = label(min(160, bounds.width / 8), .ultraLight, alpha: 0.95)
        let date = label(22, .regular, alpha: 0.7)
        let status = label(15, .medium, alpha: 0.55)
        let hint = label(13, .regular, alpha: 0.4)
        hint.stringValue = defaultHint

        let stack = NSStackView(views: [clock, date, NSView(), status, hint])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.setCustomSpacing(40, after: date)
        stack.translatesAutoresizingMaskIntoConstraints = false
        art.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: art.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: art.centerYAnchor, constant: -bounds.height * 0.04),
        ])
        clocks.append(clock); dates.append(date); countdowns.append(status); hints.append(hint)

        // Topmost: full-screen color used only during the liveness check.
        let flash = CALayer()
        flash.frame = bounds
        flash.opacity = 0
        flash.zPosition = 10
        root.addSublayer(flash)
        flashes.append(flash)

        let content = NSView(frame: bounds)
        content.addSubview(blur)
        content.addSubview(art)
        w.contentView = content
        return w
    }
}

/// Borderless windows refuse key status by default; the cover takes it so typing lands here.
private final class CoverWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
