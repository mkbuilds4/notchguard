import AppKit
import PresenceKit

// With a subcommand it behaves like `plock <command>`; with none it's the menu bar app.
let args = Array(CommandLine.arguments.dropFirst())
let command = args.first
let app = NSApplication.shared
var menuBar: MenuBarController?

if let command, PresenceCLI.commands.contains(command) {
    app.setActivationPolicy(PresenceCLI.interactive.contains(command) ? .regular : .accessory)
    Task { @MainActor in await PresenceCLI.run(command, args: args) }
} else {
    app.setActivationPolicy(.accessory)
    MainActor.assumeIsolated { menuBar = MenuBarController() }
}
app.run()
