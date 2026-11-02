import AppKit
import QuartzCore

/// Short-break cover: frosted blur of the desktop under a dark tinted wash, a drifting glow,
/// the time, and a countdown to the real lock. One window per screen, above everything.
final class Cover {
    private var windows: [NSWindow] = []
    private var timer: Timer?
    private var shownAt = Date()
    private var deadline: Date?
    /// Set for an app lock: shows the app's icon and name instead of the clock.
    private var lockedApp: (name: String, icon: NSImage)?
    private var actions: [(String, () -> Void)] = []
    private var clocks: [NSTextField] = []
    private var dates: [NSTextField] = []
    private var countdowns: [NSTextField] = []
    private var hints: [NSTextField] = []
    private var flashes: [CALayer] = []
    private let defaultHint = "Sit back down and this clears on its own"
    /// Read on each show, so Settings changes apply to the next cover.
    private var style = Config()

    var isShown: Bool { !windows.isEmpty }
    var since: Date { shownAt }

    /// `lockAfter` nil = stay up until you're back (or an intruder trips the real lock).
    /// `actions` adds buttons under the text (app lock: "Use Touch ID", "Quit").
    func show(lockAfter: TimeInterval?, app: (name: String, icon: NSImage)? = nil, actions: [(String, () -> Void)] = []) {
        guard !isShown else { return }
        lockedApp = app
        self.actions = actions
        style = Config.load()
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
        let shown = text ?? (lockedApp != nil || style.coverShowHint ? defaultHint : "")
        hints.forEach { $0.stringValue = shown }
    }

    private func tick() {
        let now = Date()
        let time = now.formatted(date: .omitted, time: .shortened)
        let day = now.formatted(.dateTime.weekday(.wide).month(.wide).day())
        let away = Int(now.timeIntervalSince(shownAt))
        _ = away
        // Only a real-lock countdown is worth showing; with no limit the line stays empty.
        let status = deadline.map { "Locks in \(mmss(max(0, Int($0.timeIntervalSince(now)))))" } ?? ""
        if let app = lockedApp {
            clocks.forEach { $0.stringValue = app.name }
            dates.forEach { $0.stringValue = "Locked" }
        } else {
            clocks.forEach { $0.stringValue = time }
            dates.forEach { $0.stringValue = day }
        }
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

        let theme = CoverTheme.named(style.coverTheme)
        let picture = backgroundPicture(for: screen)

        if let picture {
            // A plain picture, darkened enough to read the clock over it.
            let image = CALayer()
            image.frame = bounds
            image.contents = picture
            image.contentsGravity = .resizeAspectFill
            image.masksToBounds = true
            root.addSublayer(image)
            let dim = CALayer()
            dim.frame = bounds
            dim.backgroundColor = NSColor.black.withAlphaComponent(style.coverDim).cgColor
            root.addSublayer(dim)
        }

        // Dark wash: the blur alone can leave large text legible. Without the blur it's opaque.
        let wash = CAGradientLayer()
        wash.frame = bounds
        wash.colors = theme.wash.map { $0.withAlphaComponent(style.coverBlur ? $0.alphaComponent : 1).cgColor }
        wash.startPoint = CGPoint(x: 0, y: 1); wash.endPoint = CGPoint(x: 1, y: 0)
        if picture == nil { root.addSublayer(wash) }

        // Slow-drifting glows (up to two).
        for (i, color) in (picture == nil ? theme.glows : []).prefix(2).enumerated() {
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
            if picture != nil {
                // Busy pictures swallow small text; a soft shadow keeps it readable.
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
                shadow.shadowBlurRadius = 8
                shadow.shadowOffset = .zero
                l.shadow = shadow
            }
            return l
        }
        let clock = label(min(160, bounds.width / 8), .ultraLight, alpha: 0.95)
        clock.font = clockFont(size: min(160, bounds.width / 8) * (style.coverClockSize == "small" ? 0.5 : style.coverClockSize == "medium" ? 0.75 : 1))
        let date = label(22, .regular, alpha: 0.7)
        let message = label(20, .medium, alpha: 0.85)
        message.stringValue = lockedApp == nil ? style.coverMessage : ""
        message.isHidden = message.stringValue.isEmpty
        if lockedApp == nil && !style.coverShowClock { clock.isHidden = true; date.isHidden = true }
        let status = label(15, .medium, alpha: 0.55)
        let hint = label(13, .regular, alpha: 0.4)
        hint.stringValue = lockedApp == nil ? (style.coverShowHint ? defaultHint : "") : "Look at the camera to open it"
        if lockedApp != nil { clock.font = .systemFont(ofSize: 56, weight: .light) }

        var views: [NSView] = [clock, date, message, NSView(), status, hint]
        if let app = lockedApp {
            let icon = NSImageView(image: app.icon)
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 128).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 128).isActive = true
            views.insert(icon, at: 0)
        }
        if !actions.isEmpty {
            let row = NSStackView(views: actions.map { title, handler in
                let b = ActionButton(title: title, handler: handler)
                if #available(macOS 26, *) { b.bezelStyle = .glass } else { b.bezelStyle = .rounded }
                b.controlSize = .large
                return b
            })
            row.spacing = 12
            views.append(row)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.spacing = 10
        stack.setCustomSpacing(message.isHidden ? 40 : 14, after: date)
        stack.setCustomSpacing(40, after: message)
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
        if style.coverBlur && picture == nil { content.addSubview(blur) }
        content.addSubview(art)
        w.contentView = content
        return w
    }

    /// The picture for this screen, or nil for the color theme (also when the file can't be read,
    /// like a dynamic or aerial desktop picture).
    private func backgroundPicture(for screen: NSScreen) -> NSImage? {
        let url: URL?
        switch style.coverBackground {
        case "desktop": url = NSWorkspace.shared.desktopImageURL(for: screen)
        case "photo": url = style.coverPhoto.isEmpty ? nil : URL(fileURLWithPath: style.coverPhoto)
        default: url = nil
        }
        return url.flatMap { NSImage(contentsOf: $0) }.flatMap { $0.isValid ? $0 : nil }
    }

    private func clockFont(size: CGFloat) -> NSFont {
        let (weight, design): (NSFont.Weight, NSFontDescriptor.SystemDesign) = switch style.coverClockStyle {
        case "bold": (.semibold, .rounded)
        case "serif": (.regular, .serif)
        case "mono": (.light, .monospaced)
        default: (.ultraLight, .rounded)
        }
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        return base.fontDescriptor.withDesign(design).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }
}

/// Wash and glow colors for the cover, picked in Settings.
struct CoverTheme {
    let wash: [NSColor]
    let glows: [NSColor]

    static func named(_ name: String) -> CoverTheme {
        func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> NSColor { NSColor(red: r, green: g, blue: b, alpha: a) }
        let night = [c(0.04, 0.05, 0.09, 0.80), c(0.07, 0.06, 0.13, 0.86)]
        switch name {
        case "sunset":
            return CoverTheme(wash: [c(0.10, 0.04, 0.06, 0.80), c(0.12, 0.06, 0.04, 0.86)],
                              glows: [c(0.98, 0.45, 0.25, 0.35), c(0.90, 0.25, 0.45, 0.25)])
        case "forest":
            return CoverTheme(wash: [c(0.03, 0.08, 0.06, 0.80), c(0.04, 0.07, 0.09, 0.86)],
                              glows: [c(0.20, 0.75, 0.50, 0.30), c(0.25, 0.55, 0.85, 0.22)])
        case "midnight":
            return CoverTheme(wash: night, glows: [])
        case "mono":
            return CoverTheme(wash: [c(0.06, 0.06, 0.06, 0.82), c(0.09, 0.09, 0.09, 0.88)],
                              glows: [c(1, 1, 1, 0.10), c(1, 1, 1, 0.06)])
        default:
            return CoverTheme(wash: night, glows: [c(0.20, 0.45, 0.95, 0.35), c(0.85, 0.35, 0.65, 0.25)])
        }
    }
}

/// Borderless windows refuse key status by default; the cover takes it so typing lands here.
private final class ActionButton: NSButton {
    private var handler: () -> Void = {}
    convenience init(title: String, handler: @escaping () -> Void) {
        self.init(title: title, target: nil, action: nil)
        self.handler = handler
        target = self
        action = #selector(fire)
    }
    @objc private func fire() { handler() }
}

private final class CoverWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
