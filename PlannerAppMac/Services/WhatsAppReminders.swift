import AppKit
import Foundation
import SwiftData

/// The two daily digests: the morning one lists TODAY's appointments, the afternoon one
/// lists TOMORROW's, so there is time to prepare.
enum ReminderSlot: String, CaseIterable, Identifiable {
    case today, tomorrow

    var id: String { rawValue }

    var title: String { self == .today ? "Today's appointments" : "Tomorrow's appointments" }

    /// Default send time, minutes after midnight (08:00 and 15:00).
    var defaultMinutes: Int { self == .today ? 8 * 60 : 15 * 60 }

    var timeKey: String { "waReminders.\(rawValue).minutes" }
    fileprivate var lastSentKey: String { "waReminders.\(rawValue).lastSent" }
}

/// How the digest reaches WhatsApp.
enum WhatsAppDelivery: String, CaseIterable, Identifiable {
    /// Fully automatic, through the Hermes gateway's WhatsApp bridge (`hermes send`).
    case hermes
    /// Opens WhatsApp with the message pre-filled — you press Send. Needs no setup.
    case whatsappApp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hermes:      return "Automatic (Hermes WhatsApp)"
        case .whatsappApp: return "Open WhatsApp (you press Send)"
        }
    }
}

/// Daily WhatsApp digests of appointments: 8 am → today's, 3 pm → tomorrow's (times are
/// adjustable in Settings). Runs inside the Mac app, so Planner has to be running — it
/// checks every minute and catches up after sleep, as long as it is still within a few
/// hours of the scheduled time. Each digest is sent at most once per day.
@MainActor
final class WhatsAppReminders: ObservableObject {
    static let shared = WhatsAppReminders()

    static let enabledKey = "waReminders.enabled"
    static let phoneKey = "waReminders.phone"
    static let deliveryKey = "waReminders.delivery"
    static let skipEmptyKey = "waReminders.skipEmpty"
    static let statusKey = "waReminders.lastStatus"
    /// No built-in number: the repo is public, so the recipient is entered in Settings
    /// (stored locally under `phoneKey`). Sending reports "no WhatsApp number set" until then.
    static let defaultPhone = ""

    /// A digest missed by more than this (Mac asleep or Planner closed) is skipped rather
    /// than sent hours late.
    private static let catchUpWindow: TimeInterval = 4 * 3600
    /// Automatic sends retry once a minute on failure (e.g. network still down after
    /// wake), up to this many attempts per digest per day.
    private static let maxAttempts = 5

    /// Outcome of the most recent send, shown in Settings. Persisted across launches.
    @Published private(set) var lastStatus: String
    @Published private(set) var isSending = false

    private var context: ModelContext?
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var attempts: [String: Int] = [:]

    private let defaults = UserDefaults.standard

    private init() {
        lastStatus = UserDefaults.standard.string(forKey: Self.statusKey) ?? ""
    }

    // MARK: - Settings

    var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    var phoneDigits: String {
        let raw = defaults.string(forKey: Self.phoneKey) ?? Self.defaultPhone
        return raw.filter(\.isNumber)
    }

    var delivery: WhatsAppDelivery {
        defaults.string(forKey: Self.deliveryKey).flatMap(WhatsAppDelivery.init) ?? .hermes
    }

    func minutes(for slot: ReminderSlot) -> Int {
        defaults.object(forKey: slot.timeKey) as? Int ?? slot.defaultMinutes
    }

    // MARK: - Scheduling

    /// Starts the once-a-minute check. Safe to call more than once.
    func start(context: ModelContext) {
        self.context = context
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { _ in
            Task { @MainActor in WhatsAppReminders.shared.tick() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            // Give the network a moment to come back before catching up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                Task { @MainActor in WhatsAppReminders.shared.tick() }
            }
        }
        enabledDidChange()
        tick()
    }

    /// Call when the enable switch flips. Keeps App Nap from deferring the minute timer
    /// while reminders are on, and — when switching on — treats digests whose time has
    /// already passed today as done, so enabling at 10 am doesn't fire the 8 am one.
    func enabledDidChange(justEnabled: Bool = false) {
        if isEnabled {
            if activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiatedAllowingIdleSystemSleep],
                    reason: "Daily WhatsApp appointment reminders")
            }
            if justEnabled {
                let now = Date()
                for slot in ReminderSlot.allCases where now >= dueTime(slot, on: now) {
                    defaults.set(Self.dayStamp(now), forKey: slot.lastSentKey)
                }
            }
        } else if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    /// Call when a send time changes: a digest moved to later today becomes due again.
    func timeDidChange(_ slot: ReminderSlot) {
        let now = Date()
        if now < dueTime(slot, on: now) {
            defaults.removeObject(forKey: slot.lastSentKey)
        }
    }

    private func dueTime(_ slot: ReminderSlot, on day: Date) -> Date {
        Calendar.current.startOfDay(for: day).addingTimeInterval(TimeInterval(minutes(for: slot) * 60))
    }

    func tick(now: Date = Date()) {
        guard isEnabled, context != nil, !isSending else { return }
        let stamp = Self.dayStamp(now)
        for slot in ReminderSlot.allCases {
            let due = dueTime(slot, on: now)
            guard now >= due, now < due.addingTimeInterval(Self.catchUpWindow),
                  defaults.string(forKey: slot.lastSentKey) != stamp else { continue }
            let attemptKey = "\(stamp)-\(slot.rawValue)"
            guard attempts[attemptKey, default: 0] < Self.maxAttempts else { continue }
            attempts[attemptKey, default: 0] += 1
            // Mark first so an overlapping tick can't send it twice; cleared on failure.
            defaults.set(stamp, forKey: slot.lastSentKey)
            Task { await send(slot, now: now, automatic: true) }
            return   // one at a time; the other slot (if also due) goes on the next tick
        }
    }

    // MARK: - Sending

    /// Builds and delivers one digest. `automatic` sends respect "skip empty days" and
    /// un-mark the day on failure so the next minute retries.
    func send(_ slot: ReminderSlot, now: Date = Date(), automatic: Bool = false) async {
        guard let context else { return }
        guard !phoneDigits.isEmpty else {
            record("Not sent — no WhatsApp number set.")
            return
        }
        let appointments = Self.appointments(for: slot, now: now, context: context)
        if automatic, appointments.isEmpty, defaults.bool(forKey: Self.skipEmptyKey) {
            record("\(slot.title): none, so nothing was sent (\(Self.statusTime(now))).")
            return
        }
        let message = Self.message(for: slot, appointments: appointments, now: now)

        isSending = true
        defer { isSending = false }
        let error: String?
        switch delivery {
        case .hermes:      error = await Self.sendViaHermes(message, to: phoneDigits)
        case .whatsappApp: error = Self.openWhatsApp(message, to: phoneDigits)
        }

        if let error {
            if automatic { defaults.removeObject(forKey: slot.lastSentKey) }
            record("\(slot.title) failed (\(Self.statusTime(Date()))): \(error)")
        } else {
            let verb = delivery == .hermes ? "sent" : "opened in WhatsApp"
            let n = appointments.count
            record("\(slot.title) \(verb) \(Self.statusTime(Date())) — \(n) appointment\(n == 1 ? "" : "s").")
        }
    }

    private func record(_ status: String) {
        lastStatus = status
        defaults.set(status, forKey: Self.statusKey)
    }

    // MARK: - Message

    /// Active appointments on the slot's day, in time order. Everyone's appointments are
    /// included (the assignee is shown), since this digest is the owner's overview.
    static func appointments(for slot: ReminderSlot, now: Date, context: ModelContext) -> [PlannerItem] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: slot == .today ? now : cal.date(byAdding: .day, value: 1, to: now) ?? now)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return [] }
        let descriptor = FetchDescriptor<PlannerItem>(
            predicate: #Predicate { $0.kindRaw == "appointment" && !$0.isArchived },
            sortBy: [SortDescriptor(\.date)])
        return ((try? context.fetch(descriptor)) ?? []).filter { item in
            guard let date = item.date else { return false }
            return date >= start && date < end
        }
    }

    static func message(for slot: ReminderSlot, appointments: [PlannerItem], now: Date) -> String {
        let cal = Calendar.current
        let day = slot == .today ? now : cal.date(byAdding: .day, value: 1, to: now) ?? now
        let dayLabel = day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        var lines = ["📅 *\(slot.title)* — \(dayLabel)", ""]
        if appointments.isEmpty {
            lines.append(slot == .today ? "No appointments today." : "No appointments tomorrow.")
        } else {
            for item in appointments {
                var line = "• \(timeLabel(item.date))  \(item.title)"
                let who = item.assignedTo.trimmingCharacters(in: .whitespacesAndNewlines)
                if !who.isEmpty { line += " (\(who))" }
                if let link = item.meetingLink { line += "\n   🔗 \(link)" }
                lines.append(line)
            }
        }
        lines += ["", "— Planner"]
        return lines.joined(separator: "\n")
    }

    /// "9:00 AM", or "All day" for date-only appointments (stored at midnight).
    private static func timeLabel(_ date: Date?) -> String {
        guard let date else { return "" }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        if parts.hour == 0 && parts.minute == 0 { return "All day" }
        return date.formatted(date: .omitted, time: .shortened)
    }

    // MARK: - Delivery

    /// `hermes send` through the gateway's WhatsApp bridge. Returns an error message, or
    /// nil on success. The message goes in on stdin so no shell quoting is involved.
    private static func sendViaHermes(_ message: String, to digits: String) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            // Login shell for the user's PATH; ~/.local/bin is where hermes installs.
            process.arguments = ["-lc", "export PATH=\"$HOME/.local/bin:$PATH\"; "
                                 + "exec hermes send --to \"$PLANNER_WA_TARGET\" --file -"]
            var env = ProcessInfo.processInfo.environment
            env["PLANNER_WA_TARGET"] = "whatsapp:\(digits)@s.whatsapp.net"
            process.environment = env
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = output
            do {
                try process.run()
            } catch {
                return "couldn't start hermes (\(error.localizedDescription))"
            }
            input.fileHandleForWriting.write(Data(message.utf8))
            try? input.fileHandleForWriting.close()

            // Don't let a wedged gateway hang the app's sending state forever.
            let deadline = DispatchTime.now() + 90
            DispatchQueue.global().asyncAfter(deadline: deadline) {
                if process.isRunning { process.terminate() }
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus != 0 else { return nil }
            let text = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if process.terminationReason == .uncaughtSignal { return "hermes send timed out" }
            if process.terminationStatus == 127 { return "hermes not found (expected ~/.local/bin/hermes)" }
            let lastLine = text.split(separator: "\n").last.map(String.init) ?? ""
            return lastLine.isEmpty ? "hermes send exited with \(process.terminationStatus)" : lastLine
        }.value
    }

    /// Opens WhatsApp (desktop app, else WhatsApp Web) on the chat with the text filled in.
    private static func openWhatsApp(_ message: String, to digits: String) -> String? {
        var app = URLComponents(string: "whatsapp://send")!
        app.queryItems = [URLQueryItem(name: "phone", value: digits),
                          URLQueryItem(name: "text", value: message)]
        if let url = app.url, NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
            return nil
        }
        var web = URLComponents(string: "https://wa.me/\(digits)")!
        web.queryItems = [URLQueryItem(name: "text", value: message)]
        guard let url = web.url, NSWorkspace.shared.open(url) else { return "couldn't open WhatsApp" }
        return nil
    }

    // MARK: - Helpers

    private static func dayStamp(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func statusTime(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}
