import Foundation
import SwiftData
import UserNotifications

/// Schedules local "heads-up" notifications for upcoming dated items — by default 3 days
/// before the item is due.
///
/// Design notes:
/// - Local notifications only (no push, no server). Nothing leaves the device.
/// - Requests are keyed by the item's UUID (`reminder-<uuid>`) so rescheduling is just a
///   remove-then-add: no duplicates when an item's date is edited or synced from iCloud.
/// - The whole set is rebuilt from the store on launch / foreground / data change. That keeps
///   CloudKit-synced edits from other devices honest without tracking deltas.
/// - Fire times in the past are skipped: iOS would deliver them immediately, which reads as a
///   bug to the user. An item due within the lead window simply gets no advance alert.
enum ReminderScheduler {

    /// How far ahead of an item's date the alert fires. Persisted in `UserDefaults`.
    enum LeadTime: Int, CaseIterable, Identifiable {
        case oneDay = 1
        case threeDays = 3
        case oneWeek = 7

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .oneDay:    return "1 day before"
            case .threeDays: return "3 days before"
            case .oneWeek:   return "1 week before"
            }
        }
    }

    // MARK: - Settings (UserDefaults-backed)

    private static let enabledKey = "reminders.enabled"
    private static let leadDaysKey = "reminders.leadDays"
    private static let identifierPrefix = "reminder-"

    /// Master on/off switch. Defaults to **on** — the alert is the point of the feature.
    static var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: enabledKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Lead time in days; defaults to 3 per the app spec.
    static var leadTime: LeadTime {
        get {
            let raw = UserDefaults.standard.integer(forKey: leadDaysKey)
            return LeadTime(rawValue: raw) ?? .threeDays
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: leadDaysKey) }
    }

    // MARK: - Authorization

    /// Ask for alert permission. Safe to call repeatedly — iOS only prompts once.
    @discardableResult
    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    // MARK: - Scheduling

    /// Rebuild every pending reminder from the current store contents.
    ///
    /// Call on launch, on foreground, and whenever items change. Cheap enough to run wholesale:
    /// it only touches dated, active items and iOS caps us at 64 pending requests anyway.
    @MainActor
    static func rescheduleAll(context: ModelContext) async {
        let center = UNUserNotificationCenter.current()

        // Drop our previous requests; leave any non-reminder requests untouched.
        let pending = await center.pendingNotificationRequests()
        let ours = pending.map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: ours)

        guard isEnabled else { return }
        guard await authorizationStatus() == .authorized else { return }

        let descriptor = FetchDescriptor<PlannerItem>(
            predicate: #Predicate { !$0.isArchived }
        )
        guard let items = try? context.fetch(descriptor) else { return }

        // Soonest first, so if we hit the 64-request ceiling we keep the most imminent alerts.
        let upcoming = items
            .compactMap { item -> (PlannerItem, Date)? in
                guard let fireDate = fireDate(for: item) else { return nil }
                return (item, fireDate)
            }
            .sorted { $0.1 < $1.1 }
            .prefix(60)

        for (item, fireDate) in upcoming {
            try? await center.add(request(for: item, at: fireDate))
        }
    }

    /// When the advance alert for `item` should fire, or `nil` if it needs none
    /// (no date, already done, or the lead window has already passed).
    static func fireDate(for item: PlannerItem, now: Date = Date()) -> Date? {
        guard !item.isArchived, !item.isDone, let due = item.date else { return nil }
        guard let fire = Calendar.current.date(byAdding: .day,
                                               value: -leadTime.rawValue,
                                               to: due) else { return nil }
        // Never schedule into the past — iOS would fire it instantly.
        guard fire > now else { return nil }
        return fire
    }

    private static func request(for item: PlannerItem, at fireDate: Date) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = item.kind == .appointment ? "Upcoming appointment" : "Upcoming to-do"
        content.body = body(for: item)
        content.sound = .default
        content.userInfo = ["itemID": item.id.uuidString]

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

        return UNNotificationRequest(identifier: identifierPrefix + item.id.uuidString,
                                     content: content,
                                     trigger: trigger)
    }

    /// e.g. `Submit ATO — in 3 days, Sat 18 Jul at 10:54`
    private static func body(for item: PlannerItem) -> String {
        var text = item.title
        if let due = item.date {
            let when = due.formatted(.dateTime.weekday().day().month().hour().minute())
            let days = leadTime.rawValue
            text += " — in \(days) day\(days == 1 ? "" : "s"), \(when)"
        }
        return text
    }

    /// Remove every pending reminder (used when the user switches the feature off).
    static func cancelAll() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ours = pending.map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: ours)
    }
}
