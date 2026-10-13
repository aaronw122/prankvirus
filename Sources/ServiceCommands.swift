import Foundation

/// Settings shared by the `prankvirus start` command and the background service.
/// Both run as the same user, so they share one defaults domain.
enum Settings {
    private static let defaults = UserDefaults(suiteName: "prankvirus")!
    private static let timeoutKey = "timeoutMinutes"

    /// Minutes before an effect turns itself off; nil means never.
    static var timeoutMinutes: Int? {
        get {
            let value = defaults.integer(forKey: timeoutKey)
            return value > 0 ? value : nil
        }
        set {
            if let newValue { defaults.set(newValue, forKey: timeoutKey) }
            else { defaults.removeObject(forKey: timeoutKey) }
            defaults.synchronize()
        }
    }
}

/// `prankvirus start [-MINUTES]` and `prankvirus stop`: thin wrappers around
/// `brew services`, which cannot pass options to the app it launches.
enum ServiceCommands {
    /// Parses `-30`, `30` or nothing. Returns nil for "no timeout".
    static func parseMinutes(_ args: ArraySlice<String>) -> Int?? {
        guard let arg = args.first else { return .some(nil) }
        guard args.count == 1 else { return nil }
        let digits = arg.hasPrefix("-") ? String(arg.dropFirst()) : arg
        guard let minutes = Int(digits), minutes > 0 else { return nil }
        return .some(minutes)
    }

    static func start(_ args: ArraySlice<String>) -> Int32 {
        guard let minutes = parseMinutes(args) else {
            print("usage: prankvirus start [-MINUTES]   e.g. prankvirus start -30")
            return 64
        }
        Settings.timeoutMinutes = minutes
        // restart, not start: the service reads the timeout only at launch.
        let status = brew(["services", "restart", "prankvirus"])
        guard status == 0 else { return status }
        if let minutes {
            print("PrankVirus is running. Each effect turns itself off after \(minutes) minute\(minutes == 1 ? "" : "s").")
        } else {
            print("PrankVirus is running. Each effect stays on until its hotkey is pressed again.")
        }
        print("Control-Option-Command-G: glitch   Control-Option-Command-S: shift")
        return 0
    }

    static func stop() -> Int32 {
        brew(["services", "stop", "prankvirus"])
    }

    @discardableResult
    private static func brew(_ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["brew"] + args
        do {
            try process.run()
        } catch {
            print("Could not run brew: \(error.localizedDescription)")
            return 1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
