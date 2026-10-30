import Foundation
import SwiftData
import EventKit
import Combine

/// Two-way sync between Planner appointments and one or more calendars in the system
/// Calendar — typically Google accounts (e.g. personal angchewhoe@… and work angch@…) added in
/// Settings ▸ Apps ▸ Calendar ▸ Accounts (iOS) or System Settings ▸ Internet Accounts (macOS).
///
/// Design notes:
/// - **On-device only.** EventKit reads and writes the local calendar database; the account
///   owner (Apple/Google) does the actual network sync. No OAuth, no stored secrets.
/// - **Every chosen calendar holds every appointment.** A Planner appointment is added to each
///   chosen calendar, and an event that appears in one of them comes into Planner and from
///   there is copied to the others. So the personal and the work calendar both show everything.
/// - **Stable links.** An item stores its first event's `calendarItemExternalIdentifier` (for
///   Google this is the event's iCal UID — the same on the iPhone and the Mac). The copies
///   Planner writes carry a final `Planner id: <uuid>` line in their notes — the convention
///   the agents use too — so each device finds them in every calendar without new model
///   fields. Each device also remembers which event it linked in which calendar.
/// - **Planner → Calendar:** to-dos are never added. Finishing an appointment leaves its events
///   alone (the meeting still happened); events are only removed when Planner created them and
///   the item stops being a dated appointment. Invites organised by someone else are never
///   edited or removed. An event deleted in a calendar is not put back there.
/// - **Calendar → Planner** (optional, on by default): events from today onward appear as
///   Planner appointments. Declined and cancelled events are skipped. A Calendar-side change to
///   a linked event (moved, renamed) is pulled into the item, then pushed to the other copies.
/// - **Conflicts:** per link we remember the last state both sides agreed on. Whichever side
///   differs from it changed; if both did, Planner wins — unless the event is an invite from
///   someone else, in which case the organiser's version wins.
/// - **Opt-in.** Off until the user enables it; enabling asks for Calendar access.
enum CalendarSync {

    static let enabledKey = "calendar.syncEnabled"
    static let calendarIDsKey = "calendar.syncCalendarIDs"
    /// v2.5 single-calendar choice, still read when no list has been saved.
    static let calendarIDKey = "calendar.targetCalendarID"
    static let importKey = "calendar.importEvents"
    private static let agreedKey = "calendar.agreedState"
    private static let seenKey = "calendar.seenEvents"
    private static let linksKey = "calendar.links"

    /// Whether appointments sync with the system Calendar. Off by default — writing to
    /// someone's real calendar is not something to do uninvited.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// The calendars to sync with (`EKCalendar.calendarIdentifier`s; device-local ids).
    static var calendarIDs: [String] {
        get {
            if let ids = UserDefaults.standard.stringArray(forKey: calendarIDsKey) { return ids }
            let legacy = UserDefaults.standard.string(forKey: calendarIDKey) ?? ""
            return legacy.isEmpty ? [] : [legacy]
        }
        set { UserDefaults.standard.set(newValue, forKey: calendarIDsKey) }
    }

    /// Whether events from the calendars are brought into Planner (on unless turned off).
    static var importsEvents: Bool {
        get { UserDefaults.standard.object(forKey: importKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: importKey) }
    }

    /// How far ahead calendar events are brought into Planner.
    private static let importDays = 60
    /// How far ahead appointments are copied to the calendars and kept in step.
    private static let horizonDays = 365
    /// Linked pairs this far back are still kept in step (a meeting moved to yesterday).
    private static let backfillDays = 7
    /// An item made on another device is only copied to a calendar once it is this old, giving
    /// that device time to write its copies and Google time to bring them here first. The Mac
    /// runs all day, so it does this first; the iPhone waits longer.
    #if os(macOS)
    private static let adoptionGrace: TimeInterval = 10 * 60
    #else
    private static let adoptionGrace: TimeInterval = 30 * 60
    #endif
    /// Items created on this device while the app runs (e.g. by the agents' bridge on the Mac):
    /// no other device can have written their events, so they skip the grace.
    private static var localItems = Set<UUID>()

    private(set) static var store = EKEventStore()

    /// Mark an item as created here, so the next sync copies it straight away.
    static func markLocal(_ item: PlannerItem) { localItems.insert(item.id) }

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

    /// Calendars we're allowed to write into, for the list in Settings.
    static func writableCalendars() -> [EKCalendar] {
        store.calendars(for: .event).filter(\.allowsContentModifications)
    }

    /// The chosen calendars that exist and accept changes. Nothing chosen = nothing synced.
    static func syncCalendars() -> [EKCalendar] {
        var seen = Set<String>()
        return calendarIDs.compactMap { store.calendar(withIdentifier: $0) }
            .filter { $0.allowsContentModifications && seen.insert($0.calendarIdentifier).inserted }
    }

    // MARK: - One item (called right after an edit)

    /// Push one item's change to its events. Returns the link to store in `calendarEventID`.
    @discardableResult
    static func sync(_ item: PlannerItem) -> String? {
        guard isEnabled, isAuthorized else { return nil }
        guard hasFullAccess else { return writeOnlyCreate(item) }
        let calendars = syncCalendars()
        let id = itemKey(item)
        var links = linksState()[id] ?? [:]
        let found = calendars.compactMap { cal in knownEvent(for: item, in: cal, links: links).map { (cal, $0) } }
        let stored = item.calendarEventID?.isEmpty == false && !isLegacyLink(item.calendarEventID) ? item.calendarEventID : nil
        let primary = stored ?? found.first.map { linkKey($0.1) }
        guard item.kind == .appointment, item.date != nil else {
            for (_, event) in found where ownsEvent(event, item: item) {
                try? store.remove(event, span: .thisEvent, commit: true)
            }
            return found.isEmpty ? item.calendarEventID : nil
        }
        // Finished or archived: leave the events as they are.
        if item.isArchived || item.isDone { return primary }
        let now = fingerprint(item)
        for (cal, event) in found {
            links[cal.calendarIdentifier] = linkKey(event)
            guard canEdit(event), write(item, to: event, created: false) else { continue }
            agree(linkKey(event), now)
        }
        // A brand-new appointment goes to every calendar now. Copies missing for older items
        // are left to `syncAll`, which can see whether another device already wrote them.
        var created: [String] = []
        if found.isEmpty, item.calendarEventID?.isEmpty ?? true || isLegacyLink(item.calendarEventID) {
            for cal in calendars {
                let event = newEvent(in: cal)
                guard write(item, to: event, created: true) else { continue }
                let key = linkKey(event)
                links[cal.calendarIdentifier] = key
                agree(key, now)
                created.append(key)
            }
        }
        setLinks(links, for: id)
        markSeen(Set(links.values))
        return primary ?? created.first ?? item.calendarEventID
    }

    /// Legacy path when only write access was granted: create once, never read back.
    private static func writeOnlyCreate(_ item: PlannerItem) -> String? {
        guard item.kind == .appointment, item.date != nil, !item.isArchived,
              item.calendarEventID?.isEmpty ?? true,
              let calendar = syncCalendars().first ?? store.defaultCalendarForNewEvents else { return item.calendarEventID }
        let event = newEvent(in: calendar)
        return write(item, to: event, created: true) ? event.eventIdentifier : nil
    }

    // MARK: - Full sync

    /// What the last full sync did, for Settings.
    struct Summary { var imported = 0, pushed = 0, pulled = 0, created = 0, merged = 0 }

    /// One calendar's events in the sync window, indexed for linking.
    private struct CalendarIndex {
        let calendar: EKCalendar
        var events: [EKEvent]
        var byKey: [String: EKEvent] = [:]
        var byEventID: [String: EKEvent] = [:]
        var byMarker: [String: [EKEvent]] = [:]

        init(calendar: EKCalendar, events: [EKEvent]) {
            self.calendar = calendar
            self.events = events
            for event in events {
                byKey[CalendarSync.linkKey(event)] = event
                if let id = event.eventIdentifier { byEventID[id] = event }
                if let marker = CalendarSync.markerID(in: event.notes) { byMarker[String(marker.prefix(8)), default: []].append(event) }
            }
        }
    }

    /// Reconcile every appointment with every chosen calendar, both ways. Safe to re-run.
    @MainActor
    @discardableResult
    static func syncAll(context: ModelContext) -> Summary? {
        guard isEnabled, isAuthorized else { return nil }
        guard hasFullAccess else {
            legacySyncAll(context: context)
            return nil
        }
        let calendars = syncCalendars()
        guard !calendars.isEmpty else { return nil }
        var summary = Summary()
        let all = (try? context.fetch(FetchDescriptor<PlannerItem>())) ?? []
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        summary.merged = mergeDuplicates(all, context: context)
        let items = all.filter { !$0.isDeleted }

        let windowStart = cal.date(byAdding: .day, value: -backfillDays, to: today) ?? today
        let windowEnd = cal.date(byAdding: .day, value: horizonDays, to: today) ?? today
        let importEnd = cal.date(byAdding: .day, value: importDays, to: today) ?? today
        var indexes = calendars.map { calendar in
            CalendarIndex(calendar: calendar, events: store.events(matching: store.predicateForEvents(
                withStart: windowStart, end: windowEnd, calendars: [calendar])))
        }
        for i in indexes.indices { summary.merged += removeDuplicateCopies(&indexes[i]) }

        var allLinks = linksState()
        /// Events already tied to an item, as "calendar|key".
        var claimed = Set<String>()
        func claim(_ index: CalendarIndex, _ event: EKEvent) { claimed.insert(index.calendar.calendarIdentifier + "|" + linkKey(event)) }
        func isClaimed(_ index: CalendarIndex, _ event: EKEvent) -> Bool {
            claimed.contains(index.calendar.calendarIdentifier + "|" + linkKey(event))
        }

        // Pass 1: find every item's event in each calendar.
        var pairsByItem: [UUID: [(Int, EKEvent)]] = [:]
        let appointments = items.filter { $0.kind == .appointment && $0.date != nil }
        for item in appointments {
            let links = allLinks[itemKey(item)] ?? [:]
            var pairs: [(Int, EKEvent)] = []
            for (i, index) in indexes.enumerated() {
                if let event = indexedEvent(for: item, in: index, links: links) {
                    pairs.append((i, event))
                    claim(index, event)
                }
            }
            pairsByItem[item.id] = pairs
        }

        // Pass 2: keep linked pairs in step, then copy each item to the calendars it's missing from.
        for item in appointments {
            guard let date = item.date else { continue }
            let id = itemKey(item)
            var links = allLinks[id] ?? [:]
            var pairs = pairsByItem[item.id] ?? []
            // Pre-2.5 links were device-local event ids; they don't stop an item being copied.
            let wasLinked = !(item.calendarEventID?.isEmpty ?? true) && !isLegacyLink(item.calendarEventID)
            let live = !item.isArchived && !item.isDone

            // An event added by hand for this item (e.g. by an agent) counts as its copy.
            for (i, index) in indexes.enumerated() where !pairs.contains(where: { $0.0 == i }) && live && date >= today {
                if let match = index.events.first(where: { sameAppointment(item, $0) && !isClaimed(index, $0) }) {
                    pairs.append((i, match))
                    claim(index, match)
                }
            }

            for (i, event) in pairs { links[indexes[i].calendar.calendarIdentifier] = linkKey(event) }
            if let first = pairs.first, !wasLinked, item.calendarEventID != linkKey(first.1) {
                item.calendarEventID = linkKey(first.1)
            }

            if live, date >= windowStart, !pairs.isEmpty {
                switch reconcile(item, pairs.map(\.1)) {
                case .pushed: summary.pushed += 1
                case .pulled: summary.pulled += 1
                case .none: break
                }
            }

            // Missing copies. Not where this device already linked one (it was deleted there),
            // nor for an item whose event vanished everywhere (deleted in the calendar).
            let mayCopy = live && date >= today && date < windowEnd && (pairs.isEmpty ? !wasLinked : true)
                && (localItems.contains(item.id) || Date().timeIntervalSince(item.createdAt) > adoptionGrace)
            if mayCopy {
                for (i, index) in indexes.enumerated()
                where !pairs.contains(where: { $0.0 == i }) && links[index.calendar.calendarIdentifier] == nil {
                    let event = newEvent(in: index.calendar)
                    guard write(item, to: event, created: true) else { continue }
                    let key = linkKey(event)
                    links[index.calendar.calendarIdentifier] = key
                    if item.calendarEventID?.isEmpty ?? true || isLegacyLink(item.calendarEventID) { item.calendarEventID = key }
                    indexes[i].events.append(event)
                    claim(index, event)
                    agree(key, fingerprint(item))
                    summary.created += 1
                }
            }
            if !links.isEmpty { allLinks[id] = links }
        }

        // Pass 3: bring new events into Planner. The same meeting in two calendars (one invite
        // to both addresses, or entered twice) becomes one item linked to both.
        if importsEvents {
            var known = seenKeys().union(items.compactMap(\.calendarEventID))
            var imported: [PlannerItem] = []
            for index in indexes {
                for event in index.events
                where (event.startDate >= today || event.endDate > Date()) && event.startDate < importEnd {
                    let key = linkKey(event)
                    guard !isClaimed(index, event), !known.contains(key), shouldImport(event) else { continue }
                    if let twin = imported.first(where: { sameAppointment($0, event) && allLinks[itemKey($0)]?[index.calendar.calendarIdentifier] == nil }) {
                        allLinks[itemKey(twin), default: [:]][index.calendar.calendarIdentifier] = key
                        claim(index, event)
                        known.insert(key)
                        continue
                    }
                    let item = PlannerItem(title: event.title ?? "Untitled event",
                                           notes: importedNotes(event), kind: .appointment,
                                           date: event.isAllDay ? cal.startOfDay(for: event.startDate) : event.startDate)
                    item.calendarEventID = key
                    context.insert(item)
                    allLinks[itemKey(item)] = [index.calendar.calendarIdentifier: key]
                    imported.append(item)
                    claim(index, event)
                    known.insert(key)
                    agree(key, fingerprint(event))
                    summary.imported += 1
                }
            }
        }

        saveLinks(allLinks)
        markSeen(Set(claimed.map { String($0.split(separator: "|", maxSplits: 1).last ?? "") }))
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

    // MARK: - Reconcile one item with its copies

    private enum Outcome { case pushed, pulled, none }

    /// First take a change made in a calendar (the organiser's invite wins, then the most
    /// recently edited copy), then write the item to every copy that differs.
    private static func reconcile(_ item: PlannerItem, _ events: [EKEvent]) -> Outcome {
        let planner = fingerprint(item)
        let agreed = agreedState()
        var outcome = Outcome.none
        // An invite can't be edited here, so its version stands; otherwise only a copy that
        // changed while Planner didn't. When both changed, Planner wins. Invites are always
        // candidates, so two invites that disagree settle on one instead of taking turns.
        let candidates = events.filter { event in
            !canEdit(event) || (fingerprint(event) != planner && agreed[linkKey(event)] == planner)
        }
        if let source = candidates.max(by: { a, b in
            (canEdit(a) ? 0 : 1, a.lastModifiedDate ?? .distantPast) < (canEdit(b) ? 0 : 1, b.lastModifiedDate ?? .distantPast)
        }), fingerprint(source) != planner {
            apply(source, to: item)
            outcome = .pulled
        }
        let now = fingerprint(item)
        for event in events {
            let key = linkKey(event)
            if fingerprint(event) == now {
                // In step. Planner's own copies also follow note edits (comments, links).
                if ownsEvent(event, item: item), canEdit(event), event.notes != eventNotes(for: item) {
                    event.notes = eventNotes(for: item)
                    try? store.save(event, span: .thisEvent, commit: true)
                }
                agree(key, now)
                continue
            }
            guard canEdit(event), write(item, to: event, created: false) else { continue }
            agree(key, now)
            if outcome == .none { outcome = .pushed }
        }
        return outcome
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

    private static func newEvent(in calendar: EKCalendar) -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
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
        return (base.isEmpty ? "" : base + "\n\n") + "Planner id: \(itemKey(item))"
    }

    // MARK: - Importing events

    private static func shouldImport(_ event: EKEvent) -> Bool {
        if event.status == .canceled { return false }
        if let me = event.attendees?.first(where: \.isCurrentUser), me.participantStatus == .declined {
            return false
        }
        // Planner's own copies whose item was deleted stay deleted.
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

    private static func itemKey(_ item: PlannerItem) -> String { item.id.uuidString.lowercased() }

    /// The cross-device identifier of an event, plus the occurrence date for one instance of
    /// a repeating event.
    private static func linkKey(_ event: EKEvent) -> String {
        let base = event.calendarItemExternalIdentifier ?? event.eventIdentifier ?? ""
        guard event.hasRecurrenceRules, let occurrence = event.occurrenceDate else { return base }
        return base + "#" + String(Int(occurrence.timeIntervalSince1970))
    }

    /// A pre-2.5 link: `EKEvent.eventIdentifier` ("<calendar uuid>:<event uuid>"), which only
    /// means something on the device that wrote it.
    private static func isLegacyLink(_ key: String?) -> Bool {
        guard let key else { return false }
        return key.range(of: #"^[0-9A-Fa-f-]{36}:[0-9A-Fa-f-]{36}$"#, options: .regularExpression) != nil
    }

    /// Keys that may name this item's event: this device's link for the calendar, the
    /// item's stored link, and a link the agents wrote by hand ("GCal: <google event id>").
    private static func candidateKeys(for item: PlannerItem, in calendar: EKCalendar,
                                      links: [String: String]) -> [String] {
        var keys: [String] = []
        if let key = links[calendar.calendarIdentifier] { keys.append(key) }
        if let id = item.calendarEventID, !id.isEmpty { keys.append(id) }
        if let gcal = firstMatch(#"(?im)^\s*GCal:\s*(\S+)"#, in: item.notes) {
            keys += [gcal + "@google.com", gcal]
        }
        return keys
    }

    /// The item's event among one calendar's events in the window.
    private static func indexedEvent(for item: PlannerItem, in index: CalendarIndex,
                                     links: [String: String]) -> EKEvent? {
        for key in candidateKeys(for: item, in: index.calendar, links: links) {
            if let event = index.byKey[key] ?? index.byEventID[key] { return event }
        }
        return index.byMarker[String(itemKey(item).prefix(8))]?.first { ownsEvent($0, item: item) }
    }

    /// The item's event in one calendar, looked up by id wherever it is in time.
    private static func knownEvent(for item: PlannerItem, in calendar: EKCalendar,
                                   links: [String: String]) -> EKEvent? {
        let inCalendar = { (event: EKEvent) in event.calendar?.calendarIdentifier == calendar.calendarIdentifier }
        for key in candidateKeys(for: item, in: calendar, links: links) {
            let parts = key.split(separator: "#", maxSplits: 1).map(String.init)
            let occurrence = parts.count == 2 ? Double(parts[1]).map(Date.init(timeIntervalSince1970:)) : nil
            let found = store.calendarItems(withExternalIdentifier: parts[0]).compactMap { $0 as? EKEvent }.filter(inCalendar)
            if let occurrence {
                if let match = found.first(where: { $0.occurrenceDate == occurrence }) { return match }
                // Repeating events are listed once; find this instance near its date.
                let window = store.predicateForEvents(withStart: occurrence.addingTimeInterval(-86_400),
                                                      end: occurrence.addingTimeInterval(86_400),
                                                      calendars: [calendar])
                if let match = store.events(matching: window).first(where: { linkKey($0) == key }) { return match }
            } else if let first = found.first {
                return first
            }
            if let legacy = store.event(withIdentifier: key), inCalendar(legacy) { return legacy }
        }
        // A copy carrying the item's id line, near the item's date.
        guard let date = item.date else { return nil }
        let near = store.predicateForEvents(withStart: date.addingTimeInterval(-86_400),
                                            end: date.addingTimeInterval(86_400), calendars: [calendar])
        return store.events(matching: near).first { ownsEvent($0, item: item) }
    }

    /// Planner made this event (it carries the item's id line), so Planner may rewrite it.
    private static func ownsEvent(_ event: EKEvent, item: PlannerItem) -> Bool {
        guard let id = markerID(in: event.notes) else { return false }
        return itemKey(item).hasPrefix(id)
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

    /// Two devices can also both copy one item into a calendar before either sees the other's
    /// copy. Copies with the same id line are Planner's own, so the extras are removed.
    private static func removeDuplicateCopies(_ index: inout CalendarIndex) -> Int {
        var removed = Set<String>()
        for (_, group) in index.byMarker where group.count > 1 {
            let copies = group.filter { !$0.hasRecurrenceRules && canEdit($0) }
                .sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
            guard copies.count > 1, Set(copies.compactMap { markerID(in: $0.notes) }).count == 1 else { continue }
            for extra in copies.dropFirst() {
                let id = extra.eventIdentifier ?? ""
                if (try? store.remove(extra, span: .thisEvent, commit: true)) != nil { removed.insert(id) }
            }
        }
        guard !removed.isEmpty else { return 0 }
        index = CalendarIndex(calendar: index.calendar,
                              events: index.events.filter { !removed.contains($0.eventIdentifier ?? "") })
        return removed.count
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

    /// Per item, the event this device linked in each calendar: item id → calendar id → key.
    private static func linksState() -> [String: [String: String]] {
        UserDefaults.standard.dictionary(forKey: linksKey) as? [String: [String: String]] ?? [:]
    }

    private static func saveLinks(_ links: [String: [String: String]]) {
        UserDefaults.standard.set(links, forKey: linksKey)
    }

    private static func setLinks(_ links: [String: String], for item: String) {
        guard !links.isEmpty else { return }
        var all = linksState()
        all[item] = links
        saveLinks(all)
    }

    /// Events that have been linked to an item here: once its item is deleted, an event is
    /// not imported again.
    private static func seenKeys() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: seenKey) ?? [])
    }

    private static func markSeen(_ keys: Set<String>) {
        var all = UserDefaults.standard.stringArray(forKey: seenKey) ?? []
        let known = Set(all)
        all += keys.filter { !$0.isEmpty && !known.contains($0) }
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
