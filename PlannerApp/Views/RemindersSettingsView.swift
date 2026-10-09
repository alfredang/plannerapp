import SwiftUI
import SwiftData
import UserNotifications
import EventKit

/// Controls the advance alert for upcoming dated items: on/off plus how many days ahead
/// it fires (3 days by default). Changing either setting re-arms every pending alert.
struct RemindersSettingsView: View {
    @Environment(\.modelContext) private var context

    @State private var isEnabled = ReminderScheduler.isEnabled
    @State private var leadTime = ReminderScheduler.leadTime
    @State private var status: UNAuthorizationStatus = .notDetermined
    /// Whose queue the smart views show (same key as the Mac app's Settings ▸ Me).
    @AppStorage("ownerName") private var ownerName = "Alfred"
    @AppStorage(WeekStart.storageKey) private var weekStartRaw = WeekStart.defaultValue.rawValue

    /// Live iCloud sync state, so "is it syncing?" has an answer right in Settings.
    @ObservedObject private var sync = CloudSyncStatus.shared

    // Calendar mirroring (off until explicitly enabled — it writes to a real calendar).
    @AppStorage("calendar.syncEnabled") private var calendarSyncEnabled = false
    @AppStorage("calendar.targetCalendarID") private var targetCalendarID = ""
    @State private var calendars: [EKCalendar] = []

    #if os(iOS)
    // Appearance (iPhone/iPad only — the Mac has its own Light/Dark control).
    @AppStorage(AccentTheme.storageKey) private var accentRaw = AccentTheme.indigo.rawValue
    @AppStorage(AppearanceChoice.storageKey) private var appearanceRaw = AppearanceChoice.light.rawValue
    #endif

    // Day-of appointment alerts (see TodayAlerts): morning summary + alert before each.
    @AppStorage(TodayAlerts.summaryEnabledKey) private var summaryEnabled = true
    @AppStorage(TodayAlerts.summaryMinutesKey) private var summaryMinutes = TodayAlerts.defaultSummaryMinutes
    @AppStorage(TodayAlerts.leadKey) private var alertLeadRaw = TodayAlerts.Lead.fifteen.rawValue

    /// The summary time as a Date for the picker, stored as minutes after midnight.
    private var summaryTime: Binding<Date> {
        Binding {
            Calendar.current.date(byAdding: .minute, value: summaryMinutes,
                                  to: Calendar.current.startOfDay(for: Date())) ?? Date()
        } set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            summaryMinutes = (parts.hour ?? 8) * 60 + (parts.minute ?? 0)
        }
    }

    /// Count from the last backfill run, so the button reports what it did.
    @State private var backfilled: Int?

    /// True when the user has denied notifications in iOS Settings — the in-app toggle
    /// can't do anything until they re-enable it there.
    private var isBlockedBySystem: Bool {
        status == .denied
    }

    /// "Work (Google)" — the account name disambiguates same-named calendars.
    private func calendarLabel(_ cal: EKCalendar) -> String {
        let source = cal.source?.title ?? ""
        return source.isEmpty ? cal.title : "\(cal.title) (\(source))"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: sync.isOn ? "checkmark.icloud.fill" : "icloud.slash")
                        .foregroundStyle(sync.isOn ? Color.green : Color.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sync.label)
                        if let last = sync.lastSyncDate {
                            Text("Last synced \(last.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Sync Now") { sync.nudge(context: context) }
            } header: {
                Text("iCloud")
            } footer: {
                // A failed sync event is the one thing worth surfacing over the status text.
                Text(sync.lastSyncError.map { "Last sync problem: \($0)" } ?? sync.detail)
                    .foregroundStyle(sync.lastSyncError == nil ? Color.secondary : Color.orange)
            }

            #if os(iOS)
            appearanceSection
            #endif

            Section {
                Picker("Week starts on", selection: $weekStartRaw) {
                    ForEach(WeekStart.allCases) { Text($0.title).tag($0.rawValue) }
                }
            } header: {
                Text("Calendar")
            }

            Section {
                Toggle("Morning summary", isOn: $summaryEnabled)
                    .disabled(isBlockedBySystem)
                if summaryEnabled {
                    DatePicker("Time", selection: summaryTime, displayedComponents: .hourAndMinute)
                        .disabled(isBlockedBySystem)
                }
                Picker("Alert before each", selection: $alertLeadRaw) {
                    ForEach(TodayAlerts.Lead.allCases) { lead in
                        Text(lead.title).tag(lead.rawValue)
                    }
                }
                .disabled(isBlockedBySystem)
            } header: {
                Text("Today's Appointments")
            } footer: {
                Text("The morning summary lists the day's appointments; days without any stay quiet. Your own appointments (unassigned, or assigned to you) also alert you just before they start.")
            }

            Section {
                Toggle("Remind me before", isOn: $isEnabled)
                    .disabled(isBlockedBySystem)

                if isEnabled {
                    Picker("Alert me", selection: $leadTime) {
                        ForEach(ReminderScheduler.LeadTime.allCases) { lead in
                            Text(lead.title).tag(lead)
                        }
                    }
                    .disabled(isBlockedBySystem)
                }
            } header: {
                Text("Advance Reminders")
            } footer: {
                if isBlockedBySystem {
                    Text("Notifications are turned off for Planner. Enable them in iOS Settings › Notifications › Planner to get advance alerts.")
                } else {
                    Text("Get a heads-up before anything with a date is due — appointments and dated to-dos alike.")
                }
            }

            Section {
                TextField("My name", text: $ownerName)
                    #if os(iOS)
                    .textInputAutocapitalization(.words)
                    #endif
            } header: {
                Text("Me")
            } footer: {
                Text("Used by To-Do, Pinned and Today: they show only your own work — items assigned to this name, plus anything unassigned. Items assigned to someone else appear in their list instead.")
            }

            Section {
                Button("Fix Assignees from Lists") {
                    let items = (try? context.fetch(
                        FetchDescriptor<PlannerItem>(
                            predicate: #Predicate { !$0.isArchived }))) ?? []
                    backfilled = AssigneeBackfill.apply(to: items)
                }
            } header: {
                Text("Maintenance")
            } footer: {
                Text(backfilled.map { "Assigned \($0) item\($0 == 1 ? "" : "s") to their list owners." }
                     ?? "Items captured inside someone's list before the assistant filled in “Assign to” have no assignee, so they never show up in that person's queue. This fills the blank ones from the list they're in; names you typed yourself are never overwritten.")
            }

            Section {
                Toggle("Add appointments to Calendar", isOn: $calendarSyncEnabled)
                if calendarSyncEnabled, !calendars.isEmpty {
                    Picker("Calendar", selection: $targetCalendarID) {
                        Text("Default").tag("")
                        ForEach(calendars, id: \.calendarIdentifier) { cal in
                            Text(calendarLabel(cal)).tag(cal.calendarIdentifier)
                        }
                    }
                }
            } header: {
                Text("Calendar")
            } footer: {
                Text("Appointments with a date are copied into the calendar you pick. Choose your Google calendar here to have them appear in Google — add the account first in Settings ▸ Apps ▸ Calendar ▸ Accounts. To-dos are never added.")
            }

            if isBlockedBySystem {
                Section {
                    Button("Open Settings") {
                        #if os(iOS)
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                        #endif
                    }
                }
            }
        }
        .navigationTitle("Settings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            if calendarSyncEnabled { calendars = CalendarSync.writableCalendars() }
            status = await ReminderScheduler.authorizationStatus()
            // First visit with the feature on: ask, so the toggle isn't a no-op.
            if status == .notDetermined, isEnabled {
                await ReminderScheduler.requestAuthorization()
                status = await ReminderScheduler.authorizationStatus()
            }
        }
        .onChange(of: isEnabled) { _, on in
            ReminderScheduler.isEnabled = on
            Task {
                if on {
                    await ReminderScheduler.requestAuthorization()
                    status = await ReminderScheduler.authorizationStatus()
                    await ReminderScheduler.rescheduleAll(context: context)
                } else {
                    await ReminderScheduler.cancelAll()
                }
            }
        }
        .onChange(of: leadTime) { _, lead in
            ReminderScheduler.leadTime = lead
            Task { await ReminderScheduler.rescheduleAll(context: context) }
        }
        .onChange(of: summaryEnabled) { _, _ in rescheduleTodayAlerts() }
        .onChange(of: summaryMinutes) { _, _ in rescheduleTodayAlerts() }
        .onChange(of: alertLeadRaw) { _, _ in rescheduleTodayAlerts() }
        .onChange(of: calendarSyncEnabled) { _, on in
            guard on else { return }
            Task {
                // Ask for Calendar access, then back-fill every existing appointment.
                await CalendarSync.requestAccess()
                calendars = CalendarSync.writableCalendars()
                CalendarSync.syncAll(context: context)
            }
        }
        .onChange(of: targetCalendarID) { _, _ in
            // Re-mirror into the newly chosen calendar.
            CalendarSync.syncAll(context: context)
        }
    }

    #if os(iOS)
    private var appearanceSection: some View {
        Section {
            Picker("Appearance", selection: $appearanceRaw) {
                ForEach(AppearanceChoice.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 14) {
                ForEach(AccentTheme.allCases) { theme in
                    Button {
                        accentRaw = theme.rawValue
                    } label: {
                        VStack(spacing: 4) {
                            Circle()
                                .fill(theme.color)
                                .frame(width: 34, height: 34)
                                .overlay {
                                    if accentRaw == theme.rawValue {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                            Text(theme.title)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(theme.title) theme")
                    .accessibilityAddTraits(accentRaw == theme.rawValue ? .isSelected : [])
                }
            }
            .padding(.vertical, 6)
        } header: {
            Text("Appearance")
        } footer: {
            Text("Light, Dark, or follow the phone's setting — and the colour used for buttons, tabs and highlights.")
        }
    }
    #endif

    private func rescheduleTodayAlerts() {
        Task {
            // Turning an alert on is the moment to ask, if the app never has.
            if status == .notDetermined {
                await ReminderScheduler.requestAuthorization()
                status = await ReminderScheduler.authorizationStatus()
            }
            await ReminderScheduler.rescheduleAll(context: context)
        }
    }
}

#Preview {
    NavigationStack { RemindersSettingsView() }
        .modelContainer(for: PlannerItem.self, inMemory: true)
}
