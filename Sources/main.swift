import AppKit

// No Dock tile, no menu bar icon: the hotkeys are the only interface.
let app = NSApplication.shared
NSApp.setActivationPolicy(.accessory)

let delegate: NSApplicationDelegate
switch CommandLine.arguments.dropFirst().first {
case nil:
    delegate = AppDelegate()
case "check":
    delegate = HotkeyCheck()
default:
    print("""
    usage: prankvirus          run in the background (normally via `brew services start prankvirus`)
           prankvirus check    confirm both hotkeys work on this Mac
    """)
    exit(64)
}
NSApp.delegate = delegate
NSApp.run()
