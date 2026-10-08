import Foundation
import SwiftData
import UserNotifications

/// Day-of alerts for appointments — the iPhone counterpart of the Mac's WhatsApp digest:
///  * a **morning summary** (08:00 by default) listing that day's appointments, and
///  * an **alert before each** of the owner's own appointments (15 minutes by default).
///
/// Same design as `ReminderScheduler`: local notifications only, rebuilt wholesale from the
/// store (launch / foreground / data change) under their own `today-` identifiers, and never
/// scheduled into the past. Days without appointments get no summary.
enum TodayAlerts {

    /// How long before an appointment its alert fires.
    enum Lead: Int, CaseIterable, Identifiable {
        case off = -1
        case atStart = 0
        case five = 5
        case fifteen = 15
        case thirty = 30
        case hour = 60

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .off:      return "Off"
            case .atStart:  return "At start time"
            case .five:     return "5 minutes before"
            case .fifteen:  return "15 minutes before"
            case .thirty:   return "30 minutes before"
            case .hour:     return "1 hour before"
            }
        }
    }

    // MARK: - Settings (UserDefaults-backed; also bound with @AppStorage in Settings)

    static let summaryEnabledKey = "todayAlerts.summaryEnabled"
    static let summaryMinutesKey = "todayAlerts.summaryMinutes"
    static let leadKey = "todayAlerts.leadMinutes"
    static let defaultSummaryMinutes = 8 * 60
    static let identifierPrefix = "today-"

    /// Morning summaries are scheduled this many days ahead; the set is rebuilt every time
    /// the app comes forward, so a week covers anyone who opens it now and then.
    private static let summaryDays = 7
    /// Per-appointment alerts look this far ahead (and are capped), leaving room under iOS's
    /// 64-pending-request ceiling for the advance reminders.
    private static let alertHorizon: TimeInterval = 2 * 24 * 3600
    private static let maxAlerts = 15

    static var summaryEnabled: Bool {
        UserDefaults.standard.object(forKey: summaryEnabledKey) as? Bool ?? true
    }

    static var summaryMinutes: Int {
        UserDefaults.standard.object(forKey: summaryMinutesKey) as? Int ?? defaultSummaryMinutes
    }

    static var lead: Lead {
        let raw = UserDefaults.standard.object(forKey: leadKey) as? Int ?? Lead.fifteen.rawValue
        return Lead(rawValue: raw) ?? .fifteen
    }

    // MARK: - Scheduling

    /// Drop every pending `today-` request (left alone: the advance reminders).
    static func cancelAll() async {
        let center = UNUserNotificationCenter.current()
        let ours = await center.pendingNotificationRequests()
            .map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: ours)
    }

    /// Rebuild the summaries and per-appointment alerts. The caller has already checked
    /// notification permission (see `ReminderScheduler.rescheduleAll`).
    static func schedule(appointments: [PlannerItem], ownerName: String, now: Date = Date()) async {
        await cancelAll()
        let center = UNUserNotificationCenter.current()
        let active = appointments
            .filter { $0.kind == .appointment && !$0.isArchived && !$0.isDone && $0.date != nil }
            .sorted { $0.date! < $1.date! }

        if summaryEnabled {
            for request in summaryRequests(active, now: now) {
                try? await center.add(request)
            }
        }
        if lead != .off {
            for request in alertRequests(active, ownerName: ownerName, now: now) {
                try? await center.add(request)
            }
        }
    }

    /// One summary per upcoming day that has appointments, fired at the summary time.
    /// Everyone's appointments are listed (with the assignee), like the Mac digest.
    static func summaryRequests(_ appointments: [PlannerItem], now: Date) -> [UNNotificationRequest] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        return (0..<summaryDays).compactMap { offset in
            guard let day = cal.date(byAdding: .day, value: offset, to: today),
                  let next = cal.date(byAdding: .day, value: 1, to: day),
                  let fire = cal.date(byAdding: .minute, value: summaryMinutes, to: day),
                  fire > now else { return nil }
            let dayItems = appointments.filter { $0.date! >= day && $0.date! < next }
            guard !dayItems.isEmpty else { return nil }

            let content = UNMutableNotificationContent()
            let n = dayItems.count
            content.title = "Today: \(n) appointment\(n == 1 ? "" : "s")"
            content.body = dayItems.map { item in
                var line = "\(timeLabel(item.date!))  \(item.title)"
                let who = item.assignedTo.trimmingCharacters(in: .whitespacesAndNewlines)
                if !who.isEmpty { line += " (\(who))" }
                return line
            }.joined(separator: "\n")
            content.sound = .default
            // Local calendar date (the ISO-8601 style would stamp it in UTC).
            let c = cal.dateComponents([.year, .month, .day], from: day)
            let stamp = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
            return request(id: identifierPrefix + "summary-" + stamp, content: content, at: fire)
        }
    }

    /// An alert shortly before each of the owner's own timed appointments in the next two
    /// days. All-day appointments (stored at midnight) have no start to alert before.
    static func alertRequests(_ appointments: [PlannerItem], ownerName: String,
                              now: Date) -> [UNNotificationRequest] {
        let minutes = max(0, lead.rawValue)
        let horizon = now.addingTimeInterval(alertHorizon)
        let requests = appointments.compactMap { item -> UNNotificationRequest? in
            guard let start = item.date, start <= horizon, !isAllDay(start),
                  item.isMine(ownerName: ownerName) else { return nil }
            let fire = start.addingTimeInterval(TimeInterval(-minutes * 60))
            guard fire > now else { return nil }

            let content = UNMutableNotificationContent()
            content.title = item.title
            let time = start.formatted(date: .omitted, time: .shortened)
            content.body = minutes == 0
                ? "Starting now · \(time)"
                : "Starts at \(time) — in \(lead.title.replacingOccurrences(of: " before", with: ""))"
            content.sound = .default
            content.userInfo = ["itemID": item.id.uuidString]
            return request(id: identifierPrefix + "alert-" + item.id.uuidString, content: content, at: fire)
        }
        return Array(requests.prefix(maxAlerts))
    }

    // MARK: - Helpers

    private static func request(id: String, content: UNNotificationContent,
                                at fire: Date) -> UNNotificationRequest {
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: fire)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        return UNNotificationRequest(identifier: id, content: content, trigger: trigger)
    }

    private static func isAllDay(_ date: Date) -> Bool {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return parts.hour == 0 && parts.minute == 0
    }

    /// "9:00 AM", or "All day" for date-only appointments.
    private static func timeLabel(_ date: Date) -> String {
        isAllDay(date) ? "All day" : date.formatted(date: .omitted, time: .shortened)
    }
}
