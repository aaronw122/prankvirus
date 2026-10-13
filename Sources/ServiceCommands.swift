import Foundation

/// Settings shared by the `prankvirus start` command and the background service.
/// Both run as the same user, so they share one defaults domain.
enum Settings {
    private static let defaults = UserDefaults(suiteName: "prankvirus")!
    private static let timeoutKey = "timeoutMinutes"

    /// Minutes before an effect turns itself off; nil means never.
    static var timeoutMinutes: Double? {
        get {
            let value = defaults.double(forKey: timeoutKey)
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
    /// Parses `-30`, `30`, `-1.5` or nothing. Returns nil for "no timeout".
    /// Any positive, finite number of minutes is accepted, fractions included.
    static func parseMinutes(_ args: ArraySlice<String>) -> Double?? {
        guard let arg = args.first else { return .some(nil) }
        guard args.count == 1 else { return nil }
        let number = arg.hasPrefix("-") ? String(arg.dropFirst()) : arg
        guard let minutes = Double(number), minutes.isFinite, minutes > 0 else { return nil }
        return .some(minutes)
    }

    /// "1 minute", "30 minutes", "1.5 minutes", "0.25 minutes".
    static func describe(minutes: Double) -> String {
        let number = minutes.formatted(.number.precision(.fractionLength(0...3)).grouping(.never))
        return "\(number) minute\(minutes == 1 ? "" : "s")"
    }

    static func start(_ args: ArraySlice<String>) -> Int32 {
        guard let minutes = parseMinutes(args) else {
            print("usage: prankvirus start [-MINUTES]   e.g. prankvirus start -30, prankvirus start -1.5")
            return 64
        }
        Settings.timeoutMinutes = minutes
        // restart, not start: the service reads the timeout only at launch.
        let status = brew(["services", "restart", "prankvirus"])
        guard status == 0 else { return status }
        if let minutes {
            print("PrankVirus is running. Each effect turns itself off after \(describe(minutes: minutes)).")
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
