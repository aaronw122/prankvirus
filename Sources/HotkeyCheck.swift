import AppKit
import Carbon.HIToolbox

/// `prankvirus check`: confirms on this Mac that each hotkey reaches PrankVirus.
///
/// Another app registering the same combination does not block it: macOS
/// delivers a Carbon hotkey to every app that registered it (measured with two
/// processes holding Control-Option-Command-G; both received the press), so both
/// actions would run. What can stop the press arriving is an enabled macOS system
/// shortcut or a key remapper that swallows it. So the check:
/// 1. Looks the combination up in the macOS system shortcuts that are switched on.
/// 2. Asks for a real key press and waits for it to arrive.
final class HotkeyCheck: NSObject, NSApplicationDelegate {
    private static let timeout: TimeInterval = 20
    private static let modifiers = UInt32(controlKey | optionKey | cmdKey)

    private var pending: [Effect] = [.shift, .glitch]
    private var passed: [Effect] = []
    private var failed: [Effect] = []
    private var waiting: Effect?
    private var deadline: Timer?
    private var hotKeys: [EventHotKeyRef] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let other = Self.otherInstance() {
            print("""
            PrankVirus is already running (pid \(other)), so it would catch the key presses.
            Stop it, run the check, then start it again:
              brew services stop prankvirus
              prankvirus check
              brew services start prankvirus
            """)
            exit(2)
        }

        print("Checking the PrankVirus hotkeys on this Mac.\n")
        for effect in [Effect.shift, .glitch] where Self.isSystemShortcut(keyCode: effect.keyCode) {
            print("! \(effect.hotkeyLabel) is also a macOS shortcut that is switched on.")
            print("  Turn it off in System Settings > Keyboard > Keyboard Shortcuts.\n")
        }
        registerHotKeys()
        next()
    }

    private func next() {
        guard !pending.isEmpty else { finish(); return }
        let effect = pending.removeFirst()
        waiting = effect
        print("Press \(effect.hotkeyLabel) now (\(Int(Self.timeout)) seconds)... ", terminator: "")
        fflush(stdout)
        deadline = Timer.scheduledTimer(withTimeInterval: Self.timeout, repeats: false) { [weak self] _ in
            self?.resolve(effect, arrived: false)
        }
    }

    fileprivate func received(_ effect: Effect) {
        guard effect == waiting else { return }
        resolve(effect, arrived: true)
    }

    private func resolve(_ effect: Effect, arrived: Bool) {
        guard effect == waiting else { return }
        deadline?.invalidate()
        deadline = nil
        waiting = nil
        if arrived {
            passed.append(effect)
            print("works.")
        } else {
            failed.append(effect)
            print("nothing arrived.")
        }
        next()
    }

    private func finish() {
        print("")
        if failed.isEmpty {
            print("Both hotkeys work. Start it with:")
            print("  brew services start prankvirus")
            exit(0)
        }
        for effect in failed {
            print("\(effect.hotkeyLabel) did not reach PrankVirus. Something is intercepting it:")
            print("usually a key remapper such as Karabiner-Elements or BetterTouchTool, or a")
            print("shortcut in System Settings > Keyboard > Keyboard Shortcuts.")
        }
        exit(1)
    }

    private func registerHotKeys() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, let effect = Effect(rawValue: id.id) else { return status }
            let check = Unmanaged<HotkeyCheck>.fromOpaque(userData!).takeUnretainedValue()
            DispatchQueue.main.async { check.received(effect) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)

        for effect in [Effect.shift, .glitch] {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Effect.hotKeySignature, id: effect.rawValue)
            let status = RegisterEventHotKey(UInt32(effect.keyCode), Self.modifiers, id,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                hotKeys.append(ref)
            } else {
                print("! Could not register \(effect.hotkeyLabel) (error \(status)).")
            }
        }
    }

    /// Enabled macOS system shortcut with exactly Control-Option-Command and this key.
    private static func isSystemShortcut(keyCode: Int) -> Bool {
        var list: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&list) == noErr,
              let entries = list?.takeRetainedValue() as? [[String: Any]] else { return false }
        let relevant = UInt32(cmdKey | shiftKey | optionKey | controlKey)
        return entries.contains { entry in
            let code = entry[kHISymbolicHotKeyCode as String] as? Int
            let mods = (entry[kHISymbolicHotKeyModifiers as String] as? Int).map(UInt32.init) ?? 0
            let enabled = entry[kHISymbolicHotKeyEnabled as String] as? Bool ?? false
            return enabled && code == keyCode && mods & relevant == modifiers
        }
    }

    /// Pid of another running prankvirus process, if any.
    private static func otherInstance() -> Int32? {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-x", "prankvirus"]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        guard (try? pgrep.run()) != nil else { return nil }
        pgrep.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let me = ProcessInfo.processInfo.processIdentifier
        return output.split(separator: "\n").compactMap { Int32($0) }.first { $0 != me }
    }
}
