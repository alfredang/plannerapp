import Foundation
import SwiftData
import EventKit
import Combine

/// Two-way sync between Planner appointments and one calendar in the system Calendar —
/// typically a Google account (e.g. angch@…) added in Settings ▸ Apps ▸ Calendar ▸ Accounts
/// (iOS) or System Settings ▸ Internet Accounts (macOS).
///
/// Design notes:
/// - **On-device only.** EventKit reads and writes the local calendar database; the account
///   owner (Apple/Google) does the actual network sync. No OAuth, no stored secrets.
/// - **Stable links.** An item stores its event's `calendarItemExternalIdentifier` (for
///   Google this is the event's iCal UID). Unlike `eventIdentifier`, it is the same on the
///   iPhone and the Mac, so both devices find the same event instead of each adding a copy.
///   Events Planner creates also carry a final `Planner id: <uuid>` line in their notes —
///   the same convention the agents use — so a link can be recovered from either side.
/// - **Planner → Calendar:** dated appointments are created/updated in the chosen calendar.
///   To-dos never are. Finishing an appointment leaves its event alone (the meeting still
///   happened); events are only removed when Planner created them and the item stops being a
///   dated appointment. Invites organised by someone else are never edited or removed.
/// - **Calendar → Planner** (optional, on by default): events in the chosen calendar from
///   today onward appear as Planner appointments. Declined and cancelled events are skipped.
///   A Calendar-side change to a linked event (moved, renamed) is pulled into the item.
/// - **Conflicts:** per link we remember the last state both sides agreed on. Whichever side
///   differs from it changed; if both did, Planner wins — unless the event is an invite from
///   someone else, in which case the organiser's version wins.
/// - **Opt-in.** Off until the user enables it; enabling asks for Calendar access.
enum CalendarSync {

    static let enabledKey = "calendar.syncEnabled"
    static let calendarIDKey = "calendar.targetCalendarID"
    static let importKey = "calendar.importEvents"
    private static let agreedKey = "calendar.agreedState"
    private static let seenKey = "calendar.seenEvents"

    /// Whether appointments sync with the system Calendar. Off by default — writing to
    /// someone's real calendar is not something to do uninvited.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Which calendar to sync with (an `EKCalendar.calendarIdentifier`). Empty = the system
    /// default. Set this to the Google "angch@…" calendar to sync with Google.
    static var targetCalendarID: String {
        get { UserDefaults.standard.string(forKey: calendarIDKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: calendarIDKey) }
    }

    /// Whether events from the calendar are brought into Planner (on unless turned off).
    static var importsEvents: Bool {
        get { UserDefaults.standard.object(forKey: importKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: importKey) }
    }

    /// How far ahead calendar events are brought into Planner.
    private static let importDays = 60
    /// Linked pairs this far back are still kept in step (a meeting moved to yesterday).
    private static let backfillDays = 7
    /// An unlinked item is only pushed by the periodic sync once it is this old, giving the
    /// device that created it time to push it and hand the link over iCloud first.
    private static let adoptionGrace: TimeInterval = 10 * 60

    private(set) static var store = EKEventStore()

    // MARK: - Authorization

    /// Ask for full access: two-way sync has to read events, not just add them.
    @discardableResult
    static func requestAccess() async -> Bool {
        do {
            let granted: Bool
            if #available(iOS 17.0, macOS 14.0, *) {
                granted = try await store.requestFullAccessToEvents()
            } else {
                granted = try await store.requestAccess(to: .event)
            }
            // A store made before access was granted keeps seeing no calendars.
            if granted { store = EKEventStore() }
            return granted
        } catch {
            return false
        }
    }

    static var isAuthorized: Bool { hasFullAccess || hasWriteOnlyAccess }

    static var hasFullAccess: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(iOS 17.0, macOS 14.0, *) { return status == .fullAccess }
        return status == .authorized
    }

    private static var hasWriteOnlyAccess: Bool {
        if #available(iOS 17.0, macOS 14.0, *) {
            return EKEventStore.authorizationStatus(for: .event) == .writeOnly
        }
        return false
    }

    /// Calendars we're allowed to write into, for the picker in Settings.
    static func writableCalendars() -> [EKCalendar] {
        store.calendars(for: .event).filter(\.allowsContentModifications)
    }

    // MARK: - One item (called right after an edit)

    /// Push one item's change to its event. Returns the link to store in `calendarEventID`.
    @discardableResult
    static func sync(_ item: PlannerItem) -> String? {
        guard isEnabled, isAuthorized else { return nil }
        guard hasFullAccess else { return writeOnlyCreate(item) }
        let existing = linkedEvent(for: item)
        guard item.kind == .appointment, item.date != nil else {
            if let existing, ownsEvent(existing, item: item) {
                try? store.remove(existing, span: .thisEvent, commit: true)
            }
            return existing == nil ? item.calendarEventID : nil
        }
        // Finished or archived: leave the event as it is.
        if item.isArchived || item.isDone { return existing.map(linkKey) ?? item.calendarEventID }
        let event = existing ?? newEvent()
        guard existing == nil || canEdit(event) else { return linkKey(event) }
        guard write(item, to: event, created: existing == nil) else { return item.calendarEventID }
        let key = linkKey(event)
        agree(key, fingerprint(item))
        markSeen([key])
        return key
    }

    /// Legacy path when only write access was granted: create once, never read back.
    private static func writeOnlyCreate(_ item: PlannerItem) -> String? {
        guard item.kind == .appointment, item.date != nil, !item.isArchived,
              item.calendarEventID?.isEmpty ?? true else { return item.calendarEventID }
        let event = newEvent()
        return write(item, to: event, created: true) ? event.eventIdentifier : nil
    }

    /// Remove the mirrored event for an item, if Planner created it.
    static func removeEvent(for item: PlannerItem) {
        guard hasFullAccess, let event = linkedEvent(for: item), ownsEvent(event, item: item) else { return }
        try? store.remove(event, span: .thisEvent, commit: true)
    }

    // MARK: - Full sync

    /// What the last full sync did, for Settings.
    struct Summary { var imported = 0, pushed = 0, pulled = 0, created = 0, merged = 0 }

    /// Reconcile every appointment with the chosen calendar, both ways. Safe to re-run.
    @MainActor
    @discardableResult
    static func syncAll(context: ModelContext) -> Summary? {
        guard isEnabled, isAuthorized else { return nil }
        guard hasFullAccess else {
            legacySyncAll(context: context)
            return nil
        }
        guard let calendar = targetCalendar() else { return nil }
        var summary = Summary()
        let all = (try? context.fetch(FetchDescriptor<PlannerItem>())) ?? []
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        summary.merged = mergeDuplicates(all, context: context)
        let items = all.filter { !$0.isDeleted }

        // Events in the window, indexed by link key.
        let windowEnd = cal.date(byAdding: .day, value: importDays, to: today) ?? today
        let windowStart = cal.date(byAdding: .day, value: -backfillDays, to: today) ?? today
        let events = store.events(matching: store.predicateForEvents(
            withStart: windowStart, end: windowEnd, calendars: [calendar]))
        var eventsByKey: [String: EKEvent] = [:]
        for event in events { eventsByKey[linkKey(event)] = event }
        let markerOwners = Dictionary(grouping: events.compactMap { e in markerID(in: e.notes).map { ($0, e) } },
                                      by: \.0).mapValues { $0[0].1 }

        var linkedKeys = Set<String>()
        for item in items where item.kind == .appointment {
            guard let date = item.date else { continue }
            let event = eventsByKey[item.calendarEventID ?? ""]
                ?? markerOwners.first(where: { item.id.uuidString.lowercased().hasPrefix($0.key) })?.value
                ?? linkedEvent(for: item)
            if let event {
                let key = linkKey(event)
                linkedKeys.insert(key)
                if item.calendarEventID != key { item.calendarEventID = key }
                guard !item.isArchived, !item.isDone, date >= windowStart else { continue }
                switch reconcile(item, event, key: key) {
                case .pushed: summary.pushed += 1
                case .pulled: summary.pulled += 1
                case .none: break
                }
            } else if item.calendarEventID?.isEmpty ?? true,
                      !item.isArchived, !item.isDone, date >= today,
                      Date().timeIntervalSince(item.createdAt) > adoptionGrace {
                // Not in the calendar yet — but first look for one the agents added by hand.
                let match = events.first { sameAppointment(item, $0) && !linkedKeys.contains(linkKey($0)) }
                let event = match ?? newEvent()
                if match == nil {
                    guard write(item, to: event, created: true) else { continue }
                    summary.created += 1
                }
                let key = linkKey(event)
                item.calendarEventID = key
                linkedKeys.insert(key)
                agree(key, fingerprint(item))
            }
        }

        if importsEvents {
            let seen = seenKeys().union(items.compactMap(\.calendarEventID))
            for event in events where event.startDate >= today || event.endDate > Date() {
                let key = linkKey(event)
                guard !linkedKeys.contains(key), !seen.contains(key), shouldImport(event) else { continue }
                let item = PlannerItem(title: event.title ?? "Untitled event",
                                       notes: importedNotes(event), kind: .appointment,
                                       date: event.isAllDay ? cal.startOfDay(for: event.startDate) : event.startDate)
                item.calendarEventID = key
                context.insert(item)
                linkedKeys.insert(key)
                agree(key, fingerprint(event))
                summary.imported += 1
            }
        }

        markSeen(linkedKeys)
        if context.hasChanges { try? context.save() }
        return summary
    }

    /// The pre-two-way behaviour, kept for users who only granted write access.
    @MainActor
    private static func legacySyncAll(context: ModelContext) {
        let descriptor = FetchDescriptor<PlannerItem>(predicate: #Predicate { !$0.isArchived })
        guard let items = try? context.fetch(descriptor) else { return }
        for item in items where item.kind == .appointment && item.date != nil {
            if let id = writeOnlyCreate(item) { item.calendarEventID = id }
        }
    }

    // MARK: - Reconcile one linked pair

    private enum Outcome { case pushed, pulled, none }

    private static func reconcile(_ item: PlannerItem, _ event: EKEvent, key: String) -> Outcome {
        let planner = fingerprint(item)
        let calendar = fingerprint(event)
        if planner == calendar {
            // In step. Planner's own events also follow note edits (comments, links).
            if ownsEvent(event, item: item), canEdit(event), event.notes != eventNotes(for: item) {
                event.notes = eventNotes(for: item)
                try? store.save(event, span: .thisEvent, commit: true)
            }
            agree(key, planner)
            return .none
        }
        let agreed = agreedState()[key]
        let pull: Bool
        if agreed == calendar { pull = false }            // only Planner changed
        else if agreed == planner { pull = true }         // only the calendar changed
        else { pull = !canEdit(event) }                   // both: Planner wins, except invites
        if pull || !canEdit(event) {
            apply(event, to: item)
            agree(key, fingerprint(event))
            return .pulled
        }
        guard write(item, to: event, created: false) else { return .none }
        agree(key, fingerprint(item))
        return .pushed
    }

    /// Bring an event's title and time into its Planner item.
    private static func apply(_ event: EKEvent, to item: PlannerItem) {
        item.title = event.title ?? item.title
        if event.isAllDay {
            item.date = Calendar.current.startOfDay(for: event.startDate)
        } else {
            item.date = event.startDate
            item.notes = notes(item.notes, settingDuration: event.endDate.timeIntervalSince(event.startDate))
        }
    }

    // MARK: - Writing events

    private static func newEvent() -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.calendar = targetCalendar()
        return event
    }

    private static func write(_ item: PlannerItem, to event: EKEvent, created: Bool) -> Bool {
        guard let date = item.date else { return false }
        event.title = item.title
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        if parts.hour == 0 && parts.minute == 0 {
            // Date-only appointment → an all-day event.
            event.isAllDay = true
            event.startDate = date
            event.endDate = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date
        } else {
            event.isAllDay = false
            event.startDate = date
            // End read from the title/notes ("(9am–6pm)", "duration: 90m"), else an hour.
            event.endDate = item.endDate ?? date.addingTimeInterval(3600)
        }
        if created || ownsEvent(event, item: item) {
            event.notes = eventNotes(for: item)
            if let link = item.meetingLink, event.location?.isEmpty ?? true {
                event.location = MeetingLink.url(for: link)?.absoluteString ?? link
            }
        }
        do {
            try store.save(event, span: .thisEvent, commit: true)
            return true
        } catch {
            return false
        }
    }

    /// The item's notes plus the link line back to Planner.
    private static func eventNotes(for item: PlannerItem) -> String {
        let base = strippingMarker(item.notes)
        return (base.isEmpty ? "" : base + "\n\n") + "Planner id: \(item.id.uuidString.lowercased())"
    }

    // MARK: - Importing events

    private static func shouldImport(_ event: EKEvent) -> Bool {
        if event.status == .canceled { return false }
        if let me = event.attendees?.first(where: \.isCurrentUser), me.participantStatus == .declined {
            return false
        }
        // Planner's own events whose item was deleted stay deleted.
        return markerID(in: event.notes) == nil
    }

    private static func importedNotes(_ event: EKEvent) -> String {
        var lines: [String] = []
        let body = strippingMarker(event.notes ?? "")
        if !body.isEmpty { lines.append(body) }
        if let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty {
            if let link = MeetingLink.find(in: location), MeetingLink.find(in: body) == nil {
                lines.append("\(MeetingLink.tag) \(link)")
            } else if MeetingLink.find(in: location) == nil {
                lines.append("Location: \(location)")
            }
        }
        if let url = event.url?.absoluteString, url.hasPrefix("http"),
           MeetingLink.find(in: lines.joined(separator: "\n")) == nil {
            lines.append("\(MeetingLink.tag) \(url)")
        }
        var notes = lines.joined(separator: "\n")
        if !event.isAllDay {
            notes = Self.notes(notes, settingDuration: event.endDate.timeIntervalSince(event.startDate))
        }
        return notes
    }

    // MARK: - Links

    /// The key stored in `calendarEventID`: the event's cross-device identifier, plus the
    /// occurrence date for one instance of a repeating event.
    private static func linkKey(_ event: EKEvent) -> String {
        let base = event.calendarItemExternalIdentifier ?? event.eventIdentifier ?? ""
        guard event.hasRecurrenceRules, let occurrence = event.occurrenceDate else { return base }
        return base + "#" + String(Int(occurrence.timeIntervalSince1970))
    }

    /// Find an item's event outside the sync window, or from a legacy device-local id.
    private static func linkedEvent(for item: PlannerItem) -> EKEvent? {
        var candidates: [String] = []
        if let id = item.calendarEventID, !id.isEmpty { candidates.append(id) }
        // A link the agents wrote by hand: "GCal: <google event id>".
        if let gcal = firstMatch(#"(?im)^\s*GCal:\s*(\S+)"#, in: item.notes) {
            candidates += [gcal + "@google.com", gcal]
        }
        for key in candidates {
            let parts = key.split(separator: "#", maxSplits: 1).map(String.init)
            let occurrence = parts.count == 2 ? Double(parts[1]).map(Date.init(timeIntervalSince1970:)) : nil
            let found = store.calendarItems(withExternalIdentifier: parts[0]).compactMap { $0 as? EKEvent }
            if let occurrence {
                if let match = found.first(where: { $0.occurrenceDate == occurrence }) { return match }
                // Repeating events are listed once; find this instance near its date.
                let window = store.predicateForEvents(withStart: occurrence.addingTimeInterval(-86_400),
                                                      end: occurrence.addingTimeInterval(86_400),
                                                      calendars: found.first.flatMap { $0.calendar }.map { [$0] })
                if let match = store.events(matching: window).first(where: { linkKey($0) == key }) { return match }
            } else if let first = found.first {
                return first
            }
            if let legacy = store.event(withIdentifier: key) { return legacy }
        }
        return nil
    }

    /// Planner made this event (it carries the item's id line), so Planner may rewrite it.
    private static func ownsEvent(_ event: EKEvent, item: PlannerItem) -> Bool {
        guard let id = markerID(in: event.notes) else { return false }
        return item.id.uuidString.lowercased().hasPrefix(id)
    }

    /// Editable here: the calendar allows changes and it isn't someone else's invite.
    private static func canEdit(_ event: EKEvent) -> Bool {
        guard event.calendar?.allowsContentModifications ?? false else { return false }
        guard event.hasAttendees, let organizer = event.organizer else { return true }
        return organizer.isCurrentUser
    }

    /// Same title and start: an event added by hand (e.g. by an agent) for this item.
    private static func sameAppointment(_ item: PlannerItem, _ event: EKEvent) -> Bool {
        guard let date = item.date, abs(event.startDate.timeIntervalSince(date)) < 60 else { return false }
        let a = item.title.trimmingCharacters(in: .whitespaces).lowercased()
        let b = (event.title ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return !a.isEmpty && (a == b || a.hasPrefix(b) || b.hasPrefix(a))
    }

    /// Two devices can import the same event at once; keep the oldest copy.
    @MainActor
    private static func mergeDuplicates(_ items: [PlannerItem], context: ModelContext) -> Int {
        let linked = items.filter { !($0.calendarEventID?.isEmpty ?? true) && !$0.isArchived }
        var removed = 0
        for (_, group) in Dictionary(grouping: linked, by: { $0.calendarEventID ?? "" }) where group.count > 1 {
            let sorted = group.sorted { $0.createdAt < $1.createdAt }
            for extra in sorted.dropFirst()
            where extra.title == sorted[0].title && extra.date == sorted[0].date {
                context.delete(extra)
                removed += 1
            }
        }
        return removed
    }

    // MARK: - Remembered state

    /// Title + start, the fields both sides edit. The end is left out on purpose: Planner
    /// reads it from text ("(9am–5pm)"), and that guess must never move a real event.
    private static func fingerprint(_ item: PlannerItem) -> String {
        guard let date = item.date else { return "" }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return fingerprint(title: item.title, start: date, allDay: parts.hour == 0 && parts.minute == 0)
    }

    private static func fingerprint(_ event: EKEvent) -> String {
        event.isAllDay
            ? fingerprint(title: event.title ?? "", start: Calendar.current.startOfDay(for: event.startDate), allDay: true)
            : fingerprint(title: event.title ?? "", start: event.startDate, allDay: false)
    }

    private static func fingerprint(title: String, start: Date, allDay: Bool) -> String {
        [title.trimmingCharacters(in: .whitespacesAndNewlines),
         String(Int(start.timeIntervalSince1970 / 60)), allDay ? "all-day" : "timed"]
            .joined(separator: "|")
    }

    private static func agreedState() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: agreedKey) as? [String: String] ?? [:]
    }

    private static func agree(_ key: String, _ fingerprint: String) {
        var state = agreedState()
        state[key] = fingerprint
        if state.count > 3000 { state = Dictionary(uniqueKeysWithValues: state.suffix(2000).map { ($0.key, $0.value) }) }
        UserDefaults.standard.set(state, forKey: agreedKey)
    }

    /// Events that have been linked to an item here: once its item is deleted, an event is
    /// not imported again.
    private static func seenKeys() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: seenKey) ?? [])
    }

    private static func markSeen(_ keys: Set<String>) {
        var all = UserDefaults.standard.stringArray(forKey: seenKey) ?? []
        let known = Set(all)
        all += keys.filter { !known.contains($0) }
        UserDefaults.standard.set(Array(all.suffix(5000)), forKey: seenKey)
    }

    // MARK: - Text helpers

    private static let markerPattern = #"(?im)^\s*Planner id:\s*([0-9a-f-]{8,36})\s*$"#

    private static func markerID(in notes: String?) -> String? {
        firstMatch(markerPattern, in: notes ?? "")?.lowercased()
    }

    private static func strippingMarker(_ text: String) -> String {
        text.replacingOccurrences(of: markerPattern, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `notes` with a `duration: Nm` line for anything but the default hour.
    private static func notes(_ notes: String, settingDuration seconds: TimeInterval) -> String {
        var text = notes.replacingOccurrences(of: #"(?im)^\s*duration:\s*\d+\s*[hm]\s*$\n?"#, with: "",
                                              options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let minutes = Int((seconds / 60).rounded())
        if minutes > 0 && minutes != 60 {
            text += (text.isEmpty ? "" : "\n") + "duration: \(minutes)m"
        }
        return text
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func targetCalendar() -> EKCalendar? {
        if !targetCalendarID.isEmpty,
           let match = store.calendar(withIdentifier: targetCalendarID) {
            return match
        }
        return store.defaultCalendarForNewEvents
    }
}

/// Runs `CalendarSync.syncAll` on its own: at launch, when the calendar database changes
/// (Google pushed something), and every couple of minutes while the app is running.
@MainActor
final class CalendarAutoSync: ObservableObject {
    static let shared = CalendarAutoSync()

    @Published private(set) var lastRun: Date?
    @Published private(set) var lastSummary: CalendarSync.Summary?

    private var container: ModelContainer?
    private var timer: Timer?
    private var pending: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    func start(container: ModelContainer, interval: TimeInterval = 120) {
        guard self.container == nil else { return }
        self.container = container
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.schedule(after: 3) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runNow() }
        }
        schedule(after: 2)
    }

    /// Coalesce bursts of change notifications (our own saves post them too).
    func schedule(after seconds: Double) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.runNow()
        }
    }

    func runNow() {
        guard let context = container?.mainContext, CalendarSync.isEnabled else { return }
        CalendarSync.store.refreshSourcesIfNecessary()
        guard let summary = CalendarSync.syncAll(context: context) else { return }
        lastRun = Date()
        lastSummary = summary
        if summary.imported + summary.pulled + summary.merged > 0 {
            Task { await ReminderScheduler.rescheduleAll(context: context) }
        }
    }
}
