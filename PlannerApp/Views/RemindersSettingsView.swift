import SwiftUI
import SwiftData
import UserNotifications

/// Controls the advance alert for upcoming dated items: on/off plus how many days ahead
/// it fires (3 days by default). Changing either setting re-arms every pending alert.
struct RemindersSettingsView: View {
    @Environment(\.modelContext) private var context

    @State private var isEnabled = ReminderScheduler.isEnabled
    @State private var leadTime = ReminderScheduler.leadTime
    @State private var status: UNAuthorizationStatus = .notDetermined
    /// Whose queue the smart views show (same key as the Mac app's Settings ▸ Me).
    @AppStorage("ownerName") private var ownerName = "Alfred"

    /// True when the user has denied notifications in iOS Settings — the in-app toggle
    /// can't do anything until they re-enable it there.
    private var isBlockedBySystem: Bool {
        status == .denied
    }

    var body: some View {
        Form {
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
            } footer: {
                if isBlockedBySystem {
                    Text("Notifications are turned off for Planner. Enable them in iOS Settings › Notifications › Planner to get advance alerts.")
                } else {
                    Text("Get a heads-up before anything with a date is due — appointments and dated to-dos alike.")
                }
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
    }
}

#Preview {
    NavigationStack { RemindersSettingsView() }
        .modelContainer(for: PlannerItem.self, inMemory: true)
}
