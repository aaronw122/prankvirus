import AppKit
import Carbon.HIToolbox

func log(_ msg: String) {
    FileHandle.standardError.write(Data("\(msg)\n".utf8))
}

/// The two overlays. Each has its own hotkey; pressing it again turns it off.
enum Effect: UInt32 {
    /// ⌃⌥⌘G: the shaky shader's jitter, RGB split and hue remap.
    case glitch = 1
    /// ⌃⌥⌘S: the whole display, menu bar and Dock included, pushed right.
    case shift = 2

    /// 'PRVX': identifies this app's hotkeys in Carbon events.
    static let hotKeySignature = OSType(0x50525658)

    var keyCode: Int {
        switch self {
        case .glitch: return kVK_ANSI_G
        case .shift: return kVK_ANSI_S
        }
    }

    var hotkeyLabel: String {
        switch self {
        case .glitch: return "Control-Option-Command-G"
        case .shift: return "Control-Option-Command-S"
        }
    }

    func makeView(screen: NSScreen) -> NSView {
        let frame = NSRect(origin: .zero, size: screen.frame.size)
        switch self {
        case .glitch:
            // The display's own colour space: the original wrote shader output to the
            // screen unconverted, so the colour table must not be colour-managed.
            let space = screen.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
            return GlitchOverlayView(frame: frame, colorSpace: space)
        case .shift: return ShiftOverlayView(frame: frame)
        }
    }
}

/// Background app with no menu bar icon or Dock tile: the hotkeys are the only
/// interface. It resamples the real desktop through private Core Animation
/// backdrop filters, so the pixels never reach this process and macOS never asks
/// for Screen Recording.
class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []
    private var hotKeys: [EventHotKeyRef] = []
    private var windows: [NSWindow] = []
    private var animationTimer: Timer?
    private var active: Effect?
    private var start: TimeInterval?
    /// Safety net: with no menu bar icon, this is the only way out that does not
    /// need the hotkey.
    private let overlayDuration: TimeInterval = 30 * 60

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupSignalHandlers()
        setupHotKeys()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        // 64 MB colour table; build it now so the first toggle doesn't stall.
        DispatchQueue.global(qos: .utility).async { ShakyColor.prewarm() }
    }

    /// Monitor plugged in/out or resolution changed: rebuild one overlay per display.
    @objc private func screenChanged() {
        log("Screens changed")
        if let active { buildWindows(active) }
    }

    /// `kill -USR1 <pid>` toggles the glitch and `kill -USR2 <pid>` the shift,
    /// same as the hotkeys.
    private func setupSignalHandlers() {
        for (sig, effect) in [(SIGUSR1, Effect.glitch), (SIGUSR2, Effect.shift)] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in self?.toggle(effect) }
            source.resume()
            signalSources.append(source)
        }
    }


    /// Same effect again turns it off; the other effect replaces it.
    func toggle(_ effect: Effect) {
        let wasActive = active
        if wasActive != nil { stop() }
        guard wasActive != effect else { return }

        active = effect
        start = ProcessInfo.processInfo.systemUptime
        buildWindows(effect)
        // 60 fps, as the original ran: the glitch's jitter re-rolls every frame.
        // The shift is static; the timer only enforces its timeout.
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            self?.update()
        }
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        log("\(effect) ON (\(Int(overlayDuration / 60))-minute timeout)")
    }

    private func buildWindows(_ effect: Effect) {
        windows.forEach { $0.close() }
        windows = NSScreen.screens.map { screen in
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.setFrame(screen.frame, display: false)
            // Above the menu bar and Dock, as the original capture overlay was, so
            // the backdrop samples (and moves) them too.
            window.level = .screenSaver
            window.isOpaque = false
            // Near-zero alpha, not .clear: a fully clear window gets no backdrop pass.
            window.backgroundColor = NSColor.white.withAlphaComponent(0.001)
            window.ignoresMouseEvents = true
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.contentView = effect.makeView(screen: screen)
            // Private window keys required by CABackdropLayer to sample behind the window:
            // stop WindowServer flattening the idle layer tree, and rebuild the hosted tree
            // so it registers the backdrop layer.
            window.setValue(false, forKey: "shouldAutoFlattenLayerTree")
            window.setValue(false, forKey: "canHostLayersInWindowServer")
            window.setValue(true, forKey: "canHostLayersInWindowServer")
            window.orderFrontRegardless()
            return window
        }
        update()
    }

    private func update() {
        guard let start else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        guard elapsed < overlayDuration else { stop(); return }
        for window in windows {
            (window.contentView as? GlitchOverlayView)?.time = elapsed
        }
    }

    private func stop() {
        animationTimer?.invalidate()
        animationTimer = nil
        if let active { log("\(active) OFF") }
        active = nil
        start = nil
        windows.forEach { $0.close() }
        windows.removeAll()
    }

    /// Global ⌃⌥⌘G and ⌃⌥⌘S (Carbon hotkeys need no Accessibility permission).
    private func setupHotKeys() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, let effect = Effect(rawValue: id.id) else { return status }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData!).takeUnretainedValue()
            DispatchQueue.main.async { delegate.toggle(effect) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)

        for effect in [Effect.glitch, .shift] {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Effect.hotKeySignature, id: effect.rawValue)
            let status = RegisterEventHotKey(
                UInt32(effect.keyCode), UInt32(controlKey | optionKey | cmdKey),
                id, GetApplicationEventTarget(), 0, &ref
            )
            if status != noErr || ref == nil {
                log("Hotkey registration failed for \(effect): \(status)")
            } else if let ref {
                hotKeys.append(ref)
            }
        }
    }
}
