import AppKit

let app = NSApplication.shared
NSApp.setActivationPolicy(.accessory)
let delegate = AppDelegate()
NSApp.delegate = delegate
NSApp.run()
