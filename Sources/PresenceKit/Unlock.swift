import AppKit
import ApplicationServices
import IOKit.pwr_mgt
import LocalAuthentication
import OpenDirectory
import Security

// MARK: - Stored login password

/// Your Mac login password in the login keychain, readable only by this signed app,
/// and only loaded into memory after Touch ID (or your password) approves it once per session.
enum Credentials {
    private static let service = "dev.mkbuilds.presence-lock"
    private static let account = "login-password"

    static var isStored: Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    /// Checks the password against your account before storing it, so a typo can't get typed at the lock screen forever.
    static func verify(_ password: String) -> Bool {
        guard let node = try? ODNode(session: .default(), type: ODNodeType(kODNodeTypeLocalNodes)),
              let record = try? node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil)
        else { return false }
        return (try? record.verifyPassword(password)) != nil
    }

    static func save(_ password: String) -> Bool {
        delete()
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: account, kSecAttrLabel as String: "Presence Lock face unlock",
                                  kSecValueData as String: Data(password.utf8)]
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }

    static func authenticate(reason: String) async -> Bool {
        (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true
    }

    /// Touch ID (falls back to your password), then the keychain read.
    static func load(reason: String) async -> Data? {
        let ctx = LAContext()
        guard (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true else { return nil }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }
}

// MARK: - Typing at the lock screen

/// Posts keystrokes at the HID tap so they reach the lock screen's password field. Needs Accessibility.
/// Adapted from Glance's KeystrokeInjector (github.com/jonnyoo/glance, MIT).
enum KeyTyper {
    static var trusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func promptForAccess() -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    }

    /// Wakes the display, clears the field, types the password, presses Return. Blocking (~0.5s).
    static func unlock(with password: Data) -> Bool {
        guard trusted, let text = String(data: password, encoding: .utf8) else { return false }
        var assertion: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("Presence Lock face unlock" as CFString, kIOPMUserActiveLocal, &assertion)
        Thread.sleep(forTimeInterval: 0.6)
        // Never type a password anywhere but the lock screen.
        guard screenIsLocked() else { log("face unlock: screen not locked at typing time, aborted"); return false }
        let src = CGEventSource(stateID: .hidSystemState)
        // ⌘→ then ⌘⌫ wipes anything already typed (positional keys, so any keyboard layout).
        key(0x7C, command: true, src); key(0x33, command: true, src)
        let utf16 = Array(text.utf16)
        var i = 0
        while i < utf16.count {
            guard screenIsLocked() else { log("face unlock: screen unlocked mid-typing, aborted"); return false }
            var end = min(i + 20, utf16.count)
            if end < utf16.count, (0xD800...0xDBFF).contains(utf16[end - 1]) { end -= 1 } // keep surrogate pairs whole
            var chunk = Array(utf16[i..<end])
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else { return false }
            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            down.post(tap: .cghidEventTap); Thread.sleep(forTimeInterval: 0.004)
            up.post(tap: .cghidEventTap); Thread.sleep(forTimeInterval: 0.004)
            i = end
        }
        guard screenIsLocked() else { return false }
        key(0x24, command: false, src) // Return
        return true
    }

    private static func key(_ code: CGKeyCode, command: Bool, _ src: CGEventSource?) {
        let cmd: CGKeyCode = 0x37
        if command, let d = CGEvent(keyboardEventSource: src, virtualKey: cmd, keyDown: true) {
            d.flags = .maskCommand; d.post(tap: .cghidEventTap); Thread.sleep(forTimeInterval: 0.012)
        }
        if let d = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true),
           let u = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false) {
            if command { d.flags = .maskCommand; u.flags = .maskCommand }
            d.post(tap: .cghidEventTap); Thread.sleep(forTimeInterval: 0.012)
            u.post(tap: .cghidEventTap); Thread.sleep(forTimeInterval: 0.012)
        }
        if command, let u = CGEvent(keyboardEventSource: src, virtualKey: cmd, keyDown: false) {
            u.post(tap: .cghidEventTap); Thread.sleep(forTimeInterval: 0.012)
        }
    }
}

// MARK: - Password setup window

final class PasswordSetup: NSObject, NSWindowDelegate {
    /// Called with true when a password was saved. Defaults to quitting (the `plock password` process).
    var onFinish: (Bool) -> Void = { _ in NSApp.terminate(nil) }
    private var finished = false
    private func done(_ ok: Bool) { guard !finished else { return }; finished = true; window.orderOut(nil); onFinish(ok) }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 250), styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
    let field = NSSecureTextField(frame: NSRect(x: 30, y: 92, width: 380, height: 26))
    let status = NSTextField(labelWithString: "")

    func begin() {
        window.title = "Presence Lock: face unlock"
        window.delegate = self
        let v = NSView(frame: window.contentRect(forFrameRect: window.frame))
        let text = NSTextField(wrappingLabelWithString:
            "To unlock when it sees you, Presence Lock types your Mac password at the lock screen. It's checked against your account, stored in your login keychain, and only loaded after Touch ID each time Presence Lock starts.")
        text.frame = NSRect(x: 30, y: 140, width: 380, height: 80)
        field.placeholderString = "Mac login password"
        status.frame = NSRect(x: 30, y: 62, width: 380, height: 20)
        status.textColor = .secondaryLabelColor
        let save = NSButton(title: "Save", target: self, action: #selector(saveTapped))
        save.keyEquivalent = "\r"
        save.frame = NSRect(x: 320, y: 20, width: 90, height: 32)
        let remove = NSButton(title: Credentials.isStored ? "Remove stored password" : "Cancel", target: self, action: #selector(removeTapped))
        remove.frame = NSRect(x: 30, y: 20, width: 200, height: 32)
        [text, field, status, save, remove].forEach(v.addSubview)
        window.contentView = v
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
    }

    @objc func saveTapped() {
        let pw = field.stringValue
        guard !pw.isEmpty else { return }
        status.stringValue = "Checking…"
        guard Credentials.verify(pw) else { status.stringValue = "That's not your Mac password."; field.stringValue = ""; return }
        guard Credentials.save(pw) else { status.stringValue = "Couldn't save to the keychain."; return }
        field.stringValue = ""
        log("face unlock: password stored")
        status.stringValue = KeyTyper.trusted ? "Saved. Face unlock is ready." : "Saved. Now allow Presence Lock under Accessibility."
        if !KeyTyper.trusted { KeyTyper.promptForAccess() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [self] in done(true) }
    }

    @objc func removeTapped() {
        if Credentials.isStored { Credentials.delete(); log("face unlock: password removed") }
        done(false)
    }

    func windowWillClose(_ notification: Notification) { done(false) }
}
