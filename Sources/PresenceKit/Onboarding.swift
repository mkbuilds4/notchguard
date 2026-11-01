import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI

// MARK: - Onboarding

enum OnboardingStep: Int, CaseIterable {
    case welcome, camera, model, face, level, unlock, done
}

@MainActor
final class OnboardingModel: ObservableObject {
    let guardian = PresenceGuard.shared
    @Published var step: OnboardingStep = .welcome
    @Published var camera: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Published var modelInstalled = PresenceGuard.shared.modelInstalled
    @Published var modelProgress: Double?
    @Published var modelError: String?
    @Published var enrolling = false
    @Published var enrolled = PresenceGuard.shared.faceEnrolled
    @Published var enrollMessage: String?
    @Published var level: ProtectionLevel = .balanced
    @Published var passwordStored = PresenceGuard.shared.passwordStored
    @Published var accessibility = PresenceGuard.shared.accessibilityGranted
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled
    var onFinish: (() -> Void)?
    private var timer: Timer?

    init() {
        // Permissions can change in System Settings while this is open.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.camera = AVCaptureDevice.authorizationStatus(for: .video)
                self.accessibility = self.guardian.accessibilityGranted
                self.passwordStored = self.guardian.passwordStored
            }
        }
    }

    func stop() { timer?.invalidate() }

    var canContinue: Bool {
        switch step {
        case .camera: camera == .authorized
        case .model: modelInstalled
        case .face: enrolled && !enrolling
        default: true
        }
    }

    func next() {
        guard let n = OnboardingStep(rawValue: step.rawValue + 1) else { finish(); return }
        step = n
        if n == .model && !modelInstalled && modelProgress == nil { installModel() }
    }

    func back() { if let p = OnboardingStep(rawValue: step.rawValue - 1) { step = p } }

    func requestCamera() {
        if camera == .denied || camera == .restricted {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
            return
        }
        Task {
            _ = await guardian.cameraAccess()
            camera = AVCaptureDevice.authorizationStatus(for: .video)
        }
    }

    func installModel() {
        modelError = nil
        modelProgress = 0
        Task {
            do {
                try await guardian.installModel { p in Task { @MainActor in self.modelProgress = p } }
                modelInstalled = true
            } catch {
                modelError = error.localizedDescription
            }
            modelProgress = nil
        }
    }

    func enroll() {
        enrolling = true
        enrollMessage = nil
        guardian.stop()
        guardian.enroll { [weak self] ok in
            guard let self else { return }
            self.enrolling = false
            self.enrolled = self.guardian.faceEnrolled
            self.enrollMessage = ok ? nil : "Setup didn't finish. Try again in good light, facing the camera."
        }
    }

    func setUpFaceUnlock() {
        guardian.setUpPassword { [weak self] _ in
            self?.passwordStored = self?.guardian.passwordStored ?? false
        }
    }

    func setOpenAtLogin(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { log("open at login: \(error.localizedDescription)") }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    func finish() {
        var c = guardian.config.with(level)
        c.faceUnlock = passwordStored
        guardian.config = c
        log("onboarding done: \(level.rawValue), face unlock \(passwordStored ? "on" : "off")")
        stop()
        onFinish?()
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 0) {
            dots.padding(.top, 34)
            Spacer(minLength: 12)
            Group {
                switch model.step {
                case .welcome: welcome
                case .camera: camera
                case .model: faceModel
                case .face: face
                case .level: level
                case .unlock: unlock
                case .done: done
                }
            }
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            .id(model.step)
            Spacer(minLength: 12)
            footer.padding(.horizontal, 28).padding(.bottom, 24)
        }
        .frame(width: 600, height: 560)
        .background { GlassBackdrop(tint: tint) }
        .animation(.spring(duration: 0.4), value: model.step)
    }

    private var tint: Color {
        switch model.step {
        case .welcome, .done: .green
        case .camera, .model: .blue
        case .face: .green
        case .level: .indigo
        case .unlock: .teal
        }
    }

    private var dots: some View {
        HStack(spacing: 7) {
            ForEach(OnboardingStep.allCases, id: \.self) { s in
                Capsule()
                    .fill(s == model.step ? Color.primary : Color.secondary.opacity(0.3))
                    .frame(width: s == model.step ? 18 : 7, height: 7)
            }
        }
        .animation(.spring(duration: 0.3), value: model.step)
    }

    // MARK: steps

    private func hero(_ symbol: String, _ title: String, _ body: String, color: Color = .green) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(color)
                .frame(width: 84, height: 84)
                .glassCard(cornerRadius: 24, tint: color)
            Text(title).font(.system(size: 26, weight: .semibold))
            Text(body)
                .font(.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var welcome: some View {
        VStack(spacing: 22) {
            hero("faceid", "Welcome to NotchGuard",
                 "It covers your screen when you walk away and locks your Mac if someone else sits down. Everything runs on this Mac: no account, no cloud, no photos leave it.")
            VStack(alignment: .leading, spacing: 10) {
                bullet("camera", "Checks for you only while you're idle, a burst every few seconds")
                bullet("lock.fill", "Someone else at your Mac: locked, and their photo sent to you")
                bullet("faceid", "Back at your desk: the cover lifts on its own")
            }
            .padding(18)
            .glassCard(cornerRadius: 18)
        }
    }

    private var camera: some View {
        VStack(spacing: 22) {
            hero("camera.fill", "Camera access",
                 "The camera turns on only while you're away from the keyboard and trackpad, a second or two at a time. Frames are checked in memory and never saved, except photos of someone who isn't you.",
                 color: .blue)
            if model.camera == .authorized {
                Label("Camera allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button(model.camera == .denied ? "Open Camera Settings…" : "Allow Camera") { model.requestCamera() }
                    .controlSize(.large).glassButton()
                if model.camera == .denied {
                    Text("Camera access was turned off. Turn on NotchGuard in System Settings, then come back.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var faceModel: some View {
        VStack(spacing: 22) {
            hero("arrow.down.circle", "Face model",
                 "NotchGuard uses InsightFace's MobileFaceNet to tell you apart from other people. Its license doesn't allow shipping it inside the app, so it's downloaded once (about 13 MB), checked, and converted on this Mac.",
                 color: .blue)
            Link("InsightFace licenses the model for non-commercial use", destination: ModelInstaller.licenseURL)
                .font(.callout)
            if model.modelInstalled {
                Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else if let p = model.modelProgress {
                VStack(spacing: 6) {
                    ProgressView(value: p).frame(width: 260)
                    Text(p < 0.95 ? "Downloading…" : "Converting…").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                if let e = model.modelError { Text(e).font(.callout).foregroundStyle(.orange).multilineTextAlignment(.center) }
                Button(model.modelError == nil ? "Download" : "Try Again") { model.installModel() }
                    .controlSize(.large).glassButton()
            }
        }
    }

    private var face: some View {
        VStack(spacing: 22) {
            hero("faceid", "Set up your face",
                 "Look at the camera, then slowly tilt your head in a circle until the ring in the notch fills. It takes about 20 seconds.")
            if model.enrolling {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Follow the notch…").foregroundStyle(.secondary) }
            } else if model.enrolled {
                VStack(spacing: 10) {
                    Label("Face set up", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Button("Set Up Again") { model.enroll() }.glassButton()
                }
            } else {
                if let m = model.enrollMessage { Text(m).font(.callout).foregroundStyle(.orange) }
                Button("Start Face Setup") { model.enroll() }
                    .controlSize(.large).glassButton()
            }
        }
    }

    private var level: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("How strict?").font(.system(size: 26, weight: .semibold))
                Text("You can change this, or fine-tune each setting, any time in Settings.")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                ForEach([ProtectionLevel.light, .balanced, .maximum]) { l in
                    levelCard(l)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 28)
            Text(model.level.summary)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 460)
        }
    }

    private func levelCard(_ l: ProtectionLevel) -> some View {
        let on = model.level == l
        return Button { model.level = l } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: l.symbol).font(.title2).foregroundStyle(on ? Color.accentColor : .secondary)
                    Spacer()
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(on ? Color.accentColor : .secondary.opacity(0.5))
                }
                Text(l.title).font(.headline)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(l.details, id: \.self) { d in
                        Text(d).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
            .contentShape(Rectangle())
            .glassCard(cornerRadius: 16, tint: on ? .accentColor : nil)
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(on ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    private var unlock: some View {
        VStack(spacing: 22) {
            hero("lock.open.fill", "Unlock with your face",
                 "Optional. When the Mac is locked and it sees you, NotchGuard types your password for you. The password stays in your login keychain, is released only after Touch ID, and is typed only at the lock screen. A MacBook camera can't see depth, so this is a convenience, not Face ID.",
                 color: .teal)
            if model.passwordStored {
                VStack(spacing: 10) {
                    Label("Password stored", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    if model.accessibility {
                        Label("Accessibility allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Allow Accessibility…") { model.guardian.requestAccessibility() }.glassButton()
                        Text("Needed to type at the lock screen.").font(.callout).foregroundStyle(.secondary)
                    }
                }
            } else {
                Button("Turn On Face Unlock…") { model.setUpFaceUnlock() }
                    .controlSize(.large).glassButton()
            }
        }
    }

    private var done: some View {
        VStack(spacing: 22) {
            hero("checkmark.seal.fill", "You're set",
                 "NotchGuard lives in your menu bar. If the menu bar is full, open NotchGuard again from Spotlight to reach Settings.")
            Toggle("Open NotchGuard at login", isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
                .toggleStyle(.switch)
                .padding(.horizontal, 18).padding(.vertical, 12)
                .glassCard(cornerRadius: 14)
                .frame(width: 320)
        }
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(.secondary)
            Text(text)
        }
    }

    private var footer: some View {
        HStack {
            if model.step != .welcome && model.step != .done {
                Button("Back") { model.back() }.disabled(model.enrolling)
            }
            Spacer()
            if model.step == .unlock && !model.passwordStored {
                Button("Not Now") { model.next() }
            }
            Button(model.step == .done ? "Start Watching" : model.step == .welcome ? "Get Started" : "Continue") { model.next() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .disabled(!model.canContinue)
        }
    }
}

/// The first-run window. Runs the whole setup; `onFinish` fires once a face is set up and a level picked.
@MainActor
public final class OnboardingWindow {
    private var window: NSWindow?
    private var model: OnboardingModel?
    private var finished = false
    /// Fires once setup is done, or when the window is closed early after a face was set up
    /// (so protection still starts, with whatever level was picked so far).
    public var onFinish: (() -> Void)?

    public init() {}

    public func show() {
        if window == nil {
            let m = OnboardingModel()
            finished = false
            m.onFinish = { [weak self] in
                self?.finished = true
                self?.onFinish?()
                self?.window?.close()
            }
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 560),
                             styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.contentViewController = NSHostingController(rootView: OnboardingView(model: m))
            w.isReleasedWhenClosed = false
            w.center()
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let self, !self.finished, PresenceGuard.shared.faceEnrolled {
                        self.finished = true
                        self.model?.finish()
                    }
                    self?.model?.stop()
                    self?.window = nil
                    self?.model = nil
                    NSApp.setActivationPolicy(.accessory)
                }
            }
            window = w
            model = m
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Saves a PNG of every step to `dir` (for checking the layout without screen-recording access).
    func snapshotSteps(to dir: URL) async {
        guard let model, let window else { return }
        try? await Task.sleep(for: .milliseconds(800))
        for step in OnboardingStep.allCases {
            model.step = step
            try? await Task.sleep(for: .milliseconds(1500))
            // Drawn offscreen, so it works with the screen locked; vibrancy and glass come out flat.
            guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: dir.appendingPathComponent("\(step.rawValue)-\(step).png"))
        }
        model.step = .welcome
    }
}
