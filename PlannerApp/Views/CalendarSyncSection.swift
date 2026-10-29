import SwiftUI
import SwiftData
import EventKit

/// Settings ▸ Calendar sync, shared by the iPhone Settings tab and the Mac Settings pane:
/// on/off, which calendar (e.g. the Google angch@… calendar), whether its events show in
/// Planner, and what the last automatic sync did.
struct CalendarSyncSection: View {
    @Environment(\.modelContext) private var context

    // Off until explicitly enabled — it writes to a real calendar.
    @AppStorage(CalendarSync.enabledKey) private var syncEnabled = false
    @AppStorage(CalendarSync.calendarIDKey) private var targetCalendarID = ""
    @AppStorage(CalendarSync.importKey) private var importsEvents = true
    @State private var calendars: [EKCalendar] = []
    @State private var hasFullAccess = CalendarSync.hasFullAccess
    @ObservedObject private var autoSync = CalendarAutoSync.shared

    var body: some View {
        Section {
            Toggle("Sync with Calendar", isOn: $syncEnabled)
            if syncEnabled, !calendars.isEmpty {
                Picker("Calendar", selection: $targetCalendarID) {
                    Text("Default").tag("")
                    ForEach(calendars, id: \.calendarIdentifier) { cal in
                        Text(label(cal)).tag(cal.calendarIdentifier)
                    }
                }
                Toggle("Show calendar events in Planner", isOn: $importsEvents)
                Button("Sync Now") { autoSync.runNow() }
            }
        } header: {
            Text("Calendar sync")
        } footer: {
            Text(footer)
        }
        .task {
            if syncEnabled { refreshCalendars() }
        }
        .onChange(of: syncEnabled) { _, on in
            guard on else { return }
            Task {
                // Ask for Calendar access, then back-fill every existing appointment.
                await CalendarSync.requestAccess()
                refreshCalendars()
                autoSync.runNow()
            }
        }
        .onChange(of: targetCalendarID) { _, _ in autoSync.runNow() }
        .onChange(of: importsEvents) { _, _ in autoSync.runNow() }
    }

    private var footer: String {
        var text = "Appointments sync both ways with the calendar you pick: Planner appointments are added there, and its events appear in Planner as appointments. Pick your Google calendar to sync with Google — add the account first in "
        #if os(iOS)
        text += "Settings ▸ Apps ▸ Calendar ▸ Calendar Accounts."
        #else
        text += "System Settings ▸ Internet Accounts."
        #endif
        text += " To-dos are never added. Invites from other people are never changed."
        if syncEnabled, !hasFullAccess {
            text += "\n\nCalendar access is limited to adding events, so events can't be shown in Planner. Allow Full Access for Planner in "
            #if os(iOS)
            text += "Settings ▸ Privacy & Security ▸ Calendars."
            #else
            text += "System Settings ▸ Privacy & Security ▸ Calendars."
            #endif
        }
        if syncEnabled, let run = autoSync.lastRun, let s = autoSync.lastSummary {
            let time = run.formatted(date: .omitted, time: .shortened)
            let changes = [(s.imported, "added from Calendar"), (s.created, "added to Calendar"),
                           (s.pushed, "updated in Calendar"), (s.pulled, "updated from Calendar")]
                .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
            text += "\n\nLast synced \(time)" + (changes.isEmpty ? " — up to date." : ": " + changes.joined(separator: ", ") + ".")
        }
        return text
    }

    private func refreshCalendars() {
        calendars = CalendarSync.writableCalendars()
            .sorted { label($0).localizedCaseInsensitiveCompare(label($1)) == .orderedAscending }
        hasFullAccess = CalendarSync.hasFullAccess
    }

    /// "angch@tertiaryinfotech.com (Google)" — the account name disambiguates same-named calendars.
    private func label(_ cal: EKCalendar) -> String {
        let source = cal.source?.title ?? ""
        return source.isEmpty || source == cal.title ? cal.title : "\(cal.title) (\(source))"
    }
}
