import AppKit
import PresenceKit

// With a subcommand it behaves like `plock <command>`; with none it's the menu bar app.
let args = Array(CommandLine.arguments.dropFirst())
let command = args.first
let app = NSApplication.shared
var menuBar: MenuBarController?

/// Opening the app again (Spotlight, Finder) while it runs opens Settings: on a full menu bar
/// macOS hides our icon behind the notch, and this is the way back in.
final class ReopenHandler: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { menuBar?.showSettings() }
        return false
    }
}
let reopenHandler = ReopenHandler()

if let command, PresenceCLI.commands.contains(command) {
    app.setActivationPolicy(PresenceCLI.interactive.contains(command) ? .regular : .accessory)
    Task { @MainActor in await PresenceCLI.run(command, args: args) }
} else {
    app.setActivationPolicy(.accessory)
    MainActor.assumeIsolated {
        menuBar = MenuBarController()
        app.delegate = reopenHandler
    }
}
app.run()
