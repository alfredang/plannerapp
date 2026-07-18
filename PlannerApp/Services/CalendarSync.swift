import Foundation
import SwiftData
import EventKit

/// Mirrors dated appointments into the system Calendar, so they show up wherever that
/// calendar syncs — including a Google account added in Settings ▸ Calendar (iOS) or
/// System Settings ▸ Internet Accounts (macOS).
///
/// Design notes:
/// - **On-device only.** EventKit writes to the local calendar database; the account owner
///   (Apple/Google) handles the actual sync. No OAuth, no network code, no stored secrets,
///   matching the app's "nothing leaves the device by our hand" stance.
/// - **One event per item.** The created event's identifier is stored back on the item
///   (`calendarEventID`), so a later edit updates that event instead of creating a second.
/// - **Appointments only.** Undated items and plain to-dos are never written — a calendar
///   entry with no time is meaningless.
/// - **Opt-in.** Off until the user enables it; enabling asks for Calendar permission.
enum CalendarSync {

    private static let enabledKey = "calendar.syncEnabled"
    private static let calendarIDKey = "calendar.targetCalendarID"

    /// Whether appointments are mirrored to the system Calendar. Off by default — writing
    /// to someone's real calendar is not something to do uninvited.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Which calendar to write into (an `EKCalendar.calendarIdentifier`). Empty = the
    /// system default. Set this to the Google "angch@…" calendar to have events land there.
    static var targetCalendarID: String {
        get { UserDefaults.standard.string(forKey: calendarIDKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: calendarIDKey) }
    }

    private static let store = EKEventStore()

    // MARK: - Authorization

    /// Ask for write access. iOS 17+/macOS 14+ use the write-only scope, which is all we need
    /// and the least invasive — we never read the user's existing events.
    @discardableResult
    static func requestAccess() async -> Bool {
        do {
            if #available(iOS 17.0, macOS 14.0, *) {
                return try await store.requestWriteOnlyAccessToEvents()
            } else {
                return try await store.requestAccess(to: .event)
            }
        } catch {
            return false
        }
    }

    static var isAuthorized: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(iOS 17.0, macOS 14.0, *) {
            return status == .fullAccess || status == .writeOnly
        }
        return status == .authorized
    }

    /// Calendars we're allowed to write into, for the picker in Settings.
    static func writableCalendars() -> [EKCalendar] {
        store.calendars(for: .event).filter(\.allowsContentModifications)
    }

    // MARK: - Sync

    /// Mirror one appointment. Creates the event on first sync, updates it thereafter.
    /// Returns the event identifier so the caller can persist it on the item.
    @discardableResult
    static func sync(_ item: PlannerItem) -> String? {
        guard isEnabled, isAuthorized else { return nil }
        // Only dated appointments belong on a calendar.
        guard item.kind == .appointment, let date = item.date, !item.isArchived else {
            removeEvent(for: item)
            return nil
        }

        // Reuse the existing event when we have one, so edits don't duplicate.
        let event: EKEvent
        if let id = item.calendarEventID, !id.isEmpty,
           let existing = store.event(withIdentifier: id) {
            event = existing
        } else {
            event = EKEvent(eventStore: store)
            event.calendar = targetCalendar()
        }

        event.title = item.title
        event.notes = item.notes.isEmpty ? nil : item.notes
        event.startDate = date
        // No duration is modelled, so default to an hour — a zero-length event is invisible
        // in most calendar UIs.
        event.endDate = date.addingTimeInterval(3600)

        do {
            try store.save(event, span: .thisEvent, commit: true)
            return event.eventIdentifier
        } catch {
            return nil
        }
    }

    /// Remove the mirrored event for an item (used when it stops being a dated appointment,
    /// or is archived/deleted).
    static func removeEvent(for item: PlannerItem) {
        guard let id = item.calendarEventID, !id.isEmpty,
              let event = store.event(withIdentifier: id) else { return }
        try? store.remove(event, span: .thisEvent, commit: true)
    }

    /// Mirror every active appointment. Safe to re-run: existing events are updated in place.
    @MainActor
    static func syncAll(context: ModelContext) {
        guard isEnabled, isAuthorized else { return }
        let descriptor = FetchDescriptor<PlannerItem>(predicate: #Predicate { !$0.isArchived })
        guard let items = try? context.fetch(descriptor) else { return }
        for item in items where item.kind == .appointment && item.date != nil {
            if let id = sync(item) { item.calendarEventID = id }
        }
    }

    private static func targetCalendar() -> EKCalendar? {
        if !targetCalendarID.isEmpty,
           let match = store.calendar(withIdentifier: targetCalendarID) {
            return match
        }
        return store.defaultCalendarForNewEvents
    }
}
