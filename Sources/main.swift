import AppKit

let args = CommandLine.arguments.dropFirst()
let usage = """
usage: prankvirus start             run in the background; effects stay on until toggled off
       prankvirus start -MINUTES    same, but each effect turns itself off after MINUTES
       prankvirus stop              turn it off, now and at login
       prankvirus check             confirm both hotkeys work on this Mac
"""

switch args.first {
case "start":
    exit(ServiceCommands.start(args.dropFirst()))
case "stop":
    exit(ServiceCommands.stop())
case "help", "-h", "--help":
    print(usage)
    exit(0)
case nil, "check":
    break
default:
    print(usage)
    exit(64)
}

// No Dock tile, no menu bar icon: the hotkeys are the only interface.
let app = NSApplication.shared
NSApp.setActivationPolicy(.accessory)
// No arguments: the background service itself, as launched by `brew services`.
let delegate: NSApplicationDelegate = args.first == "check" ? HotkeyCheck() : AppDelegate()
NSApp.delegate = delegate
NSApp.run()
