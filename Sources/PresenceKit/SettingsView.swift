import AppKit
import ServiceManagement
import SwiftUI

/// Backs the settings window: every edit to `config` is saved and pushed to the running monitor.
@MainActor
final class SettingsModel: ObservableObject {
    let guardian = PresenceGuard.shared

    @Published var config: Config {
        didSet {
            guard config != oldValue else { return }
            // A hand edit to something the level controls turns it into Custom. (Setting config here
            // doesn't re-run didSet, so fall through and hand the edit to the guardian.)
            if config.protectionLevel != .custom && ProtectionLevel.matching(config) != config.protectionLevel {
                config.protectionLevel = .custom
            }
            guardian.config = config
        }
    }

    func setLevel(_ level: ProtectionLevel) {
        guard level != .custom else { return }
        Task {
            // Going down a level loosens protection, so it needs the owner.
            if level.rank < config.protectionLevel.rank, !(await PresenceGuard.confirmOwner(reason: "lower the protection level")) { return }
            config = config.with(level)
        }
    }
    @Published var faceEnrolled = false
    @Published var samples = 0
    @Published var learned = 0
    @Published var passwordStored = false
    @Published var faceUnlockArmed = false
    @Published var accessibility = false
    @Published var paused = false
    @Published var running = false
    @Published var openAtLogin = false
    @Published var photoCount = 0
    @Published var modelInstalled = false
    /// nil = not downloading; 0...1 while the model installs.
    @Published var modelProgress: Double?
    @Published var modelError: String?

    private var timer: Timer?

    init() {
        config = PresenceGuard.shared.config
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        faceEnrolled = guardian.faceEnrolled
        samples = guardian.enrolledSamples
        learned = guardian.learnedLooks
        passwordStored = guardian.passwordStored
        faceUnlockArmed = guardian.faceUnlockArmed
        accessibility = guardian.accessibilityGranted
        paused = guardian.isPaused
        running = guardian.isRunning
        openAtLogin = SMAppService.mainApp.status == .enabled
        modelInstalled = guardian.modelInstalled
        refreshPlace()
        photoCount = (try? FileManager.default.contentsOfDirectory(atPath: guardian.intruderPhotos.path))?
            .filter { $0.hasSuffix(".jpg") }.count ?? 0
    }

    var status: (String, Color) {
        if !faceEnrolled { return ("Set up your face to start", .orange) }
        if paused { return ("Paused", .orange) }
        return running ? ("Watching while you're away", .green) : ("Not running", .secondary)
    }

    func setPaused(_ on: Bool) {
        Task {
            if on, !(await PresenceGuard.confirmOwner(reason: "pause NotchGuard")) { refresh(); return }
            guardian.setPaused(on)
            refresh()
        }
    }

    func setOpenAtLogin(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { log("open at login: \(error.localizedDescription)") }
        refresh()
    }

    func installModel() {
        modelError = nil
        modelProgress = 0
        Task {
            do {
                try await guardian.installModel { p in Task { @MainActor in self.modelProgress = p } }
            } catch {
                modelError = error.localizedDescription
            }
            modelProgress = nil
            refresh()
        }
    }

    func enroll() {
        let wasRunning = guardian.isRunning
        guardian.stop()
        guardian.enroll { [weak self] ok in
            if ok || wasRunning { self?.guardian.start() }
            self?.refresh()
        }
    }

    func setFaceUnlock(_ on: Bool) {
        if on {
            config.faceUnlock = true
            if !passwordStored {
                guardian.setUpPassword { [weak self] ok in
                    Task { if ok { _ = await self?.guardian.armFaceUnlock() }; self?.refresh() }
                }
            } else if !faceUnlockArmed {
                Task { _ = await guardian.armFaceUnlock(); refresh() }
            }
        } else {
            config.faceUnlock = false
        }
    }

    func removePassword() {
        Task {
            guard await PresenceGuard.confirmOwner(reason: "remove the stored password") else { return }
            guardian.removePassword()
            config.faceUnlock = false
            refresh()
        }
    }

    func forgetLearned() {
        Task {
            guard await PresenceGuard.confirmOwner(reason: "forget learned looks") else { return }
            guardian.forgetLearnedLooks()
            refresh()
        }
    }

    // MARK: places

    @Published var placeStatus = ""
    @Published var locationDenied = false

    func refreshPlace() {
        let w = PlaceWatcher.shared
        locationDenied = w.denied
        if config.places.isEmpty && config.schedule.isEmpty { placeStatus = "Normal everywhere"; return }
        let m = w.mode(config)
        placeStatus = "\(m.mode.title), \(m.reason)"
    }

    func addCurrentPlace(named name: String) {
        let w = PlaceWatcher.shared
        w.start()
        let loc = w.location
        let place = Place(name: name.isEmpty ? (w.ssid ?? "This place") : name,
                          bssid: w.bssid, latitude: loc?.coordinate.latitude, longitude: loc?.coordinate.longitude)
        if place.bssid == nil && place.latitude == nil {
            placeStatus = w.denied ? "Location Services is off for NotchGuard" : "Couldn't see a Wi-Fi router or location yet, try again in a moment"
            return
        }
        config.places.append(place)
        refreshPlace()
    }

    func removePlace(_ id: UUID) {
        Task {
            // Deleting a place can loosen things, so it needs the owner.
            guard await PresenceGuard.confirmOwner(reason: "remove a saved place") else { return }
            config.places.removeAll { $0.id == id }
            refreshPlace()
        }
    }

    // MARK: locked apps

    func addApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.prompt = "Lock"
        guard panel.runModal() == .OK else { return }
        let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        config.lockedApps = Array(Set(config.lockedApps + ids)).sorted { appName($0) < appName($1) }
    }

    func removeApp(_ id: String) {
        Task {
            // Unlocking an app for good needs the owner.
            guard await PresenceGuard.confirmOwner(reason: "stop locking \(appName(id))") else { return }
            config.lockedApps.removeAll { $0 == id }
        }
    }

    func appName(_ id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    func appIcon(_ id: String) -> NSImage {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general = "General", face = "Face ID", away = "Away & Cover", places = "Places & Schedule", intruders = "Intruders", apps = "Locked Apps", advanced = "Advanced"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .face: "faceid"
        case .away: "figure.walk.departure"
        case .places: "location.fill"
        case .intruders: "person.crop.circle.badge.exclamationmark"
        case .apps: "lock.app.dashed"
        case .advanced: "slider.horizontal.3"
        }
    }
    var tint: Color {
        switch self {
        case .general: .gray
        case .face: .green
        case .away: .blue
        case .places: .teal
        case .intruders: .red
        case .apps: .indigo
        case .advanced: .gray
        }
    }
}

public struct PresenceSettingsView: View {
    @StateObject private var model = SettingsModel()
    @State private var pane: SettingsPane = .general

    public init() {}

    public var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $pane) { p in
                Label {
                    Text(p.rawValue)
                } icon: {
                    Image(systemName: p.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(p.tint.gradient, in: RoundedRectangle(cornerRadius: 5))
                }
                .tag(p)
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            Form { content }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .background { GlassBackdrop(tint: pane.tint) }
                .navigationTitle(pane.rawValue)
        }
        .frame(minWidth: 680, minHeight: 500)
    }

    @ViewBuilder private var content: some View {
        switch pane {
        case .general: general
        case .face: face
        case .away: away
        case .places: places
        case .intruders: intruders
        case .apps: apps
        case .advanced: advanced
        }
    }

    // MARK: panes

    private var general: some View {
        Group {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "faceid")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(model.status.1)
                        .frame(width: 54, height: 54)
                        .glassCard(cornerRadius: 16, tint: model.status.1)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.status.0).font(.title3.weight(.semibold))
                        Text("Covers your screen when you walk away and locks the Mac if someone else sits down. Everything runs on this Mac.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }
            Section {
                Picker("Protection level", selection: Binding(get: { model.config.protectionLevel }, set: { model.setLevel($0) })) {
                    ForEach(ProtectionLevel.allCases) { l in
                        Label(l.title, systemImage: l.symbol).tag(l)
                            .selectionDisabled(l == .custom)
                    }
                }
                Toggle("Protection on", isOn: Binding(get: { !model.paused }, set: { model.setPaused(!$0) }))
                    .disabled(!model.faceEnrolled)
                Toggle("Open at login", isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
            } footer: {
                Text("\(model.config.protectionLevel.summary) Turning protection off or lowering the level asks for Touch ID.")
            }
        }
    }

    private var face: some View {
        Group {
            Section {
                if let p = model.modelProgress {
                    LabeledContent("Face model") { ProgressView(value: p).frame(width: 180) }
                } else if model.modelInstalled {
                    statusRow("Face model", ok: true, okText: "Installed", badText: "")
                } else {
                    statusRow("Face model", ok: false, okText: "", badText: model.modelError ?? "Not installed") {
                        Button("Download") { model.installModel() }.glassButton()
                    }
                }
                LabeledContent("Setup") {
                    Text(model.faceEnrolled ? "\(model.samples) angles" : "Not set up").foregroundStyle(.secondary)
                }
                LabeledContent("Learned looks") {
                    Text("\(model.learned) of 40").foregroundStyle(.secondary)
                }
                HStack {
                    Button(model.faceEnrolled ? "Set Up Again…" : "Set Up My Face…") { model.enroll() }
                    .glassButton()
                    Spacer()
                    if model.learned > 0 { Button("Forget Learned Looks", role: .destructive) { model.forgetLearned() } }
                }
            } header: {
                Text("Your face")
            } footer: {
                Text("The face model (InsightFace's MobileFaceNet, about 13 MB) is downloaded from InsightFace and converted on this Mac, because its license doesn't allow shipping it inside the app. After each confident unlock it keeps a recent look of you, so a growing beard or new glasses don't throw it off. Your original setup is never replaced.")
            }

            Section {
                Toggle("Unlock the lock screen with my face", isOn: Binding(get: { model.config.faceUnlock && model.passwordStored }, set: { model.setFaceUnlock($0) }))
                if model.config.faceUnlock && model.passwordStored {
                    Toggle("Require a blink", isOn: $model.config.lockScreenBlink)
                    statusRow("Password", ok: model.faceUnlockArmed, okText: "Stored, unlocked with Touch ID", badText: "Stored, waiting for Touch ID")
                    statusRow("Accessibility", ok: model.accessibility, okText: "Allowed", badText: "Needed to type at the lock screen") {
                        Button("Allow…") { PresenceGuard.shared.requestAccessibility() }
                    }
                    Button("Remove Stored Password", role: .destructive) { model.removePassword() }
                }
            } header: {
                Text("Face unlock")
            } footer: {
                Text("Your Mac password stays in your login keychain and is typed only while the screen is locked. A MacBook camera can't see depth, so this is a convenience, not Face ID.")
            }
        }
    }

    private var away: some View {
        Group {
            Section {
                sliderRow("Start checking after", value: $model.config.idleGrace, in: 5...60, step: 5, unit: "s idle")
                sliderRow("Check every", value: $model.config.interval, in: 2...15, step: 1, unit: "s")
                Stepper(value: $model.config.missesToLock, in: 1...5) {
                    LabeledContent("Cover after", value: "\(model.config.missesToLock) missed check\(model.config.missesToLock == 1 ? "" : "s")")
                }
            } header: {
                Text("When you step away")
            } footer: {
                Text("While you're typing or using the trackpad the camera stays off. Checks slow down on their own while it keeps seeing you.")
            }

            Section {
                Picker("Lock for real after", selection: $model.config.coverMinutes) {
                    Text("Never").tag(0.0)
                    Text("5 minutes").tag(5.0)
                    Text("15 minutes").tag(15.0)
                    Text("1 hour").tag(60.0)
                }
                Picker("Live-face check", selection: $model.config.liveCheck) {
                    Text("Natural (no prompt)").tag("natural")
                    Text("Head turn").tag("headturn")
                    Text("Screen glow").tag("glow")
                }
                if model.config.liveCheck == "glow" {
                    sliderRow("Glow strength", value: Binding(get: { Double(model.config.flashStrength) }, set: { model.config.flashStrength = Float($0) }),
                              in: 0.3...1, step: 0.1, unit: "", percent: true)
                }
            } header: {
                Text("The cover")
            } footer: {
                Text(model.config.liveCheck == "natural"
                     ? "Nothing to do: it waits for the small movement or blink you make anyway. A photo on a phone stays rigid however it's held. Only if you sit perfectly still does it ask you to move a little, any direction."
                     : model.config.liveCheck == "headturn"
                     ? "The notch asks for one random head move (left, right, up or down). A photo can't follow it and a recording can't know which move is coming."
                     : "The glow briefly lights your face so a photo on a phone can't lift the cover. Below 50% it can stop recognizing you in a bright room.")
            }
        }
    }

    @State private var newPlaceName = ""

    private var places: some View {
        Group {
            Section {
                LabeledContent("Right now") { Text(model.placeStatus).foregroundStyle(.secondary) }
                if model.locationDenied {
                    statusRow("Location Services", ok: false, okText: "", badText: "Off for NotchGuard") {
                        Button("Open Settings…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
                        }
                    }
                }
            } footer: {
                Text("Relaxed waits longer and only covers the screen. Strict locks the Mac for real as soon as you walk away. Someone else sitting down always locks it, in every mode.")
            }

            Section {
                ForEach($model.config.places) { $place in
                    HStack {
                        Image(systemName: place.bssid != nil ? "wifi" : "location").foregroundStyle(.secondary).frame(width: 18)
                        TextField("Name", text: $place.name).labelsHidden()
                        Picker("", selection: $place.mode) {
                            ForEach(GuardMode.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().frame(width: 110)
                        Button { model.removePlace(place.id) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).help("Remove (asks for Touch ID)")
                    }
                }
                HStack {
                    TextField("Name, like Home", text: $newPlaceName)
                    Button("Add This Place") { model.addCurrentPlace(named: newPlaceName); newPlaceName = "" }
                        .glassButton()
                }
                if !model.config.places.isEmpty {
                    Picker("Everywhere else", selection: $model.config.unknownPlaceMode) {
                        ForEach(GuardMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
            } header: {
                Text("Places")
            } footer: {
                Text("A place is recognized by its Wi-Fi router (not just the network name, which anyone can copy) or by location within about 150 m. macOS needs Location Services for both. Nothing leaves this Mac.")
            }

            Section {
                ForEach($model.config.schedule) { $rule in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 4) {
                            ForEach(1...7, id: \.self) { d in
                                let on = rule.days.contains(d)
                                Button(Calendar.current.veryShortWeekdaySymbols[d - 1]) {
                                    if on { rule.days.removeAll { $0 == d } } else { rule.days.append(d) }
                                }
                                .buttonStyle(.plain)
                                .frame(width: 24, height: 24)
                                .background(on ? Color.accentColor : Color.secondary.opacity(0.15), in: Circle())
                                .foregroundStyle(on ? .white : .primary)
                            }
                            Spacer()
                            Button { model.config.schedule.removeAll { $0.id == rule.id } } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }.buttonStyle(.plain)
                        }
                        HStack {
                            DatePicker("From", selection: minutesBinding($rule.start), displayedComponents: .hourAndMinute)
                            DatePicker("to", selection: minutesBinding($rule.end), displayedComponents: .hourAndMinute)
                            Picker("", selection: $rule.mode) {
                                Text("Normal").tag(GuardMode.normal)
                                Text("Strict").tag(GuardMode.strict)
                            }.labelsHidden().frame(width: 100)
                        }
                    }
                    .padding(.vertical, 2)
                }
                Button("Add Time Window") { model.config.schedule.append(ScheduleRule()) }
                    .glassButton()
            } header: {
                Text("Schedule")
            } footer: {
                Text("A time window can only make things stricter than the place you're at, so a schedule can't be used to switch protection off. An end time before the start runs past midnight.")
            }
        }
    }

    /// Minutes after midnight as a Date for DatePicker.
    private func minutesBinding(_ m: Binding<Int>) -> Binding<Date> {
        Binding(get: { Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(m.wrappedValue) * 60) },
                set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0); m.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0) })
    }

    private var intruders: some View {
        Group {
            Section {
                Toggle("Text me photos", isOn: Binding(get: { !model.config.alertTo.isEmpty }, set: { if !$0 { model.config.alertTo = "" } else if model.config.alertTo.isEmpty { model.config.alertTo = "+1" } }))
                if !model.config.alertTo.isEmpty {
                    TextField("Phone or Apple ID email", text: $model.config.alertTo)
                }
            } header: {
                Text("Alerts")
            } footer: {
                Text("Sent through the Messages app on this Mac when someone else sits down, shows a fake face, or uses the keyboard while you're away.")
            }
            Section("Photos") {
                LabeledContent("Saved", value: "\(model.photoCount) photo\(model.photoCount == 1 ? "" : "s")")
                Button("Show in Finder") { NSWorkspace.shared.open(PresenceGuard.shared.intruderPhotos) }
                .glassButton()
            }
        }
    }

    private var apps: some View {
        Section {
            if model.config.lockedApps.isEmpty {
                Text("No apps locked yet").foregroundStyle(.secondary)
            }
            ForEach(model.config.lockedApps, id: \.self) { id in
                HStack(spacing: 10) {
                    Image(nsImage: model.appIcon(id)).resizable().frame(width: 24, height: 24)
                    Text(model.appName(id))
                    Spacer()
                    Button { model.removeApp(id) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                        .help("Stop locking (asks for Touch ID)")
                }
            }
            Button("Add App…") { model.addApp() }
                .glassButton()
            Picker("Lock again after leaving it", selection: $model.config.appRelockMinutes) {
                Text("Only when I walk away").tag(0.0)
                Text("1 minute").tag(1.0)
                Text("5 minutes").tag(5.0)
                Text("15 minutes").tag(15.0)
            }
        } header: {
            Text("Need my face to open")
        } footer: {
            Text("A locked app is hidden under a cover until it sees you, with Touch ID and Quit buttons as a fallback. It always locks again when you walk away, the Mac locks, or you quit it.")
        }
    }

    private var advanced: some View {
        Group {
            Section {
                sliderRow("Match threshold", value: Binding(get: { Double(model.config.threshold) }, set: { model.config.threshold = Float($0) }),
                          in: 0.2...0.6, step: 0.05, unit: "")
                sliderRow("Stranger below", value: Binding(get: { Double(model.config.strangerMaxScore) }, set: { model.config.strangerMaxScore = Float($0) }),
                          in: 0.05...0.3, step: 0.05, unit: "")
                Toggle("Live-face checks", isOn: $model.config.liveness)
            } header: {
                Text("Recognition")
            } footer: {
                Text("You usually score 0.75 or more, other people under 0.2. Raising the threshold makes it stricter; turning off live-face checks lets a photo of you through.")
            }
            Section("Lock screen") {
                sliderRow("Look for me for", value: $model.config.unlockLookSeconds, in: 10...60, step: 5, unit: "s after a lock or wake")
            }
            Section {
                Button("Open Log") { NSWorkspace.shared.open(Paths.log) }
                Button("Open Settings File") { NSWorkspace.shared.open(Paths.config) }
            }
        }
    }

    // MARK: rows

    private func sliderRow(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double, unit: String, percent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                Text(percent ? "\(Int(value.wrappedValue * 100))%" : "\(value.wrappedValue.formatted(.number.precision(.fractionLength(step < 1 ? 2 : 0))))\(unit)")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }

    private func statusRow(_ title: String, ok: Bool, okText: String, badText: String, @ViewBuilder action: () -> some View = { EmptyView() }) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(ok ? .green : .orange)
                Text(ok ? okText : badText).foregroundStyle(.secondary)
                if !ok { action() }
            }
        }
    }
}

// MARK: - Liquid Glass

/// A soft colored wash behind the form so the glass sections have something to refract.
struct GlassBackdrop: View {
    let tint: Color
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(colors: [tint.opacity(0.22), .clear], center: .topLeading, startRadius: 20, endRadius: 520)
            RadialGradient(colors: [Color.purple.opacity(0.14), .clear], center: .bottomTrailing, startRadius: 20, endRadius: 560)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.4), value: tint)
    }
}

extension View {
    /// Liquid Glass on macOS 26, a frosted material before that.
    @ViewBuilder func glassCard(cornerRadius: CGFloat, tint: Color? = nil) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(tint.map { Glass.regular.tint($0.opacity(0.25)) } ?? .regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    @ViewBuilder func glassButton() -> some View {
        if #available(macOS 26, *) { self.buttonStyle(.glass) } else { self.buttonStyle(.bordered) }
    }
}

/// A plain window hosting the settings view (for the standalone app).
@MainActor
public final class SettingsWindow {
    private var window: NSWindow?

    public init() {}

    public func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "NotchGuard"
            w.contentViewController = NSHostingController(rootView: PresenceSettingsView())
            w.setContentSize(NSSize(width: 760, height: 540))
            // A unified toolbar is what lets the sidebar float as a Liquid Glass panel on macOS 26.
            w.toolbar = NSToolbar(identifier: "NotchGuardSettings")
            w.toolbarStyle = .unified
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.center()
            // Back to a menu bar only app (no Dock icon) once the window closes.
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                NSApp.setActivationPolicy(.accessory)
            }
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
