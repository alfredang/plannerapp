import Foundation
import ServiceManagement

/// Keeps Planner working unattended: opening at login, and the Mac-wide "don't sleep when
/// the lid closes" switch (so reminders and the agent bridge keep running in clamshell).
enum PowerSettings {

    // MARK: - Open at login

    private static let autoRegisteredKey = "loginItem.autoRegistered"

    /// Planner opens at login by default: register once, on first launch of a build with
    /// this behaviour. After that the Settings toggle owns it, so switching it off sticks.
    static func registerLoginItemOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: autoRegisteredKey) else { return }
        defaults.set(true, forKey: autoRegisteredKey)
        if SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
    }

    // MARK: - Lid-closed sleep

    /// Whether system sleep is disabled (`pmset -a disablesleep 1`), which is what keeps a
    /// MacBook running with the lid closed. Read from `pmset -g` ("SleepDisabled 1").
    static var isSleepDisabled: Bool {
        let pipe = Pipe()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["-g"]
        task.standardOutput = pipe
        guard (try? task.run()) != nil else { return false }
        task.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.split(separator: "\n").contains { line in
            let parts = line.split(whereSeparator: \.isWhitespace)
            return parts.count == 2 && parts[0] == "SleepDisabled" && parts[1] == "1"
        }
    }

    /// Changes the Mac-wide setting. Needs an administrator password — macOS shows its own
    /// prompt. Returns an error message, or nil on success.
    static func setSleepDisabled(_ disabled: Bool) -> String? {
        let source = "do shell script \"/usr/bin/pmset -a disablesleep \(disabled ? 1 : 0)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { return nil }
        // -128 = the user cancelled the password prompt.
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return "" }
        return (error[NSAppleScript.errorMessage] as? String) ?? "pmset failed"
    }

    // MARK: - Power on for the morning briefs

    /// Daily time the Mac powers itself on (`pmset repeat wakeorpoweron`), just before the
    /// first Digital Workforce job at 07:03 — so the briefs run even if the Mac was shut down.
    static let powerOnTime = "06:55:00"

    /// True when a repeating wake-or-power-on event is scheduled (`pmset -g sched`).
    static var isPowerOnScheduled: Bool {
        let pipe = Pipe()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["-g", "sched"]
        task.standardOutput = pipe
        guard (try? task.run()) != nil else { return false }
        task.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.contains("Repeating power events") && out.contains("poweron")
            || out.contains("wakepoweron")
    }

    /// Schedules (or cancels) the daily power-on. Needs an administrator password.
    /// Returns an error message, "" if cancelled, or nil on success.
    static func setPowerOnScheduled(_ on: Bool) -> String? {
        let command = on ? "/usr/bin/pmset repeat wakeorpoweron MTWRFSU \(powerOnTime)"
                         : "/usr/bin/pmset repeat cancel"
        let source = "do shell script \"\(command)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { return nil }
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return "" }
        return (error[NSAppleScript.errorMessage] as? String) ?? "pmset failed"
    }
}
