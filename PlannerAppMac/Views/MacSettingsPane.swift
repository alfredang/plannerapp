import SwiftUI
import SwiftData
import ServiceManagement

/// App settings, reachable from BOTH the sidebar (Support ▸ Settings) and the standard
/// macOS Settings window (Planner ▸ Settings…, ⌘,). One view so they never diverge.
struct MacSettingsPane: View {
    @Environment(\.modelContext) private var context
    /// Count from the last backfill run, so the button reports what it did.
    @State private var backfilled: Int?
    @AppStorage("terminalAgent") private var terminalAgentRaw = TerminalAgent.hermes.rawValue
    @AppStorage("hermesPanelVisible") private var hermesVisible = true
    /// Off by default — the agent archives instead of deleting, and cannot delete lists.
    @AppStorage(HermesBridge.allowsAgentDeletionKey) private var allowsAgentDeletion = false
    /// Whose queue the smart views show (shared with the iPhone app's key).
    @AppStorage("ownerName") private var ownerName = "Alfred"

    @AppStorage(AppearanceMode.storageKey) private var appearanceModeRaw = AppearanceMode.system.rawValue

    @AppStorage(WhatsAppReminders.enabledKey) private var remindersEnabled = false
    @AppStorage(WhatsAppReminders.phoneKey) private var reminderPhone = WhatsAppReminders.defaultPhone
    @AppStorage(WhatsAppReminders.deliveryKey) private var deliveryRaw = WhatsAppDelivery.hermes.rawValue
    @AppStorage(WhatsAppReminders.skipEmptyKey) private var skipEmptyDays = false
    @AppStorage(ReminderSlot.today.timeKey) private var todayMinutes = ReminderSlot.today.defaultMinutes
    @AppStorage(ReminderSlot.tomorrow.timeKey) private var tomorrowMinutes = ReminderSlot.tomorrow.defaultMinutes
    @ObservedObject private var reminders = WhatsAppReminders.shared
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Default mode", selection: $appearanceModeRaw) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearanceModeRaw) { AppearanceController.shared.defaultDidChange() }
                Text("Planner starts in this mode; System follows the Mac's appearance. The sun/moon button in the toolbar (⇧⌘D) flips Light ↔ Dark for the current session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            whatsAppSection

            Section("Me") {
                TextField("My name", text: $ownerName)
                Text("Used by the smart views (To-Do, Pinned, Today): they show only your own work — items assigned to this name, plus anything unassigned. Items assigned to someone else appear in their list instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Maintenance") {
                // Fetch straight from the context rather than trusting @Query: this pane is
                // presented from two different scenes and a missing container would silently
                // yield an empty list (and a permanently disabled button).
                Button("Fix Assignees from Lists") {
                    let items = (try? context.fetch(
                        FetchDescriptor<PlannerItem>(
                            predicate: #Predicate { !$0.isArchived }))) ?? []
                    backfilled = AssigneeBackfill.apply(to: items)
                }
                Text(backfilled.map { "Assigned \($0) item\($0 == 1 ? "" : "s") to their list owners." }
                     ?? "Items captured inside someone's list before the assistant filled in “Assign to” have no assignee, so they never show up in that person's queue. This fills the blank ones from the list they're in; names you typed yourself are never overwritten.")
                    .font(.caption)
                    .foregroundStyle(backfilled != nil ? .green : .secondary)
            }

            Section("Agent safety") {
                Toggle("Allow agent to delete", isOn: $allowsAgentDeletion)
                Text(allowsAgentDeletion
                     ? "The agent can permanently delete items and lists. Deleting a list orphans the items inside it."
                     : "The agent cannot delete anything. “Delete” archives the item instead (restore it from Archive), and deleting a list is refused. Recommended.")
                    .font(.caption)
                    .foregroundStyle(allowsAgentDeletion ? .orange : .secondary)
            }

            Section("Agent terminal panel") {
                Toggle("Show the agent panel", isOn: $hermesVisible)
                Picker("Terminal starts with", selection: $terminalAgentRaw) {
                    ForEach(TerminalAgent.allCases) { agent in
                        Text(agent.title).tag(agent.rawValue)
                    }
                }
                .pickerStyle(.inline)
                Text("The agent CLI must be on your PATH (e.g. ~/.local/bin). Changing this restarts the terminal panel. Shortcut: ⌥⌘T toggles the panel; drag its divider to resize.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }

    // MARK: - WhatsApp reminders

    private var whatsAppSection: some View {
        Section("WhatsApp reminders") {
            Toggle("Send daily appointment reminders", isOn: $remindersEnabled)
                .onChange(of: remindersEnabled) {
                    reminders.enabledDidChange(justEnabled: remindersEnabled)
                }
            TextField("WhatsApp number", text: $reminderPhone, prompt: Text("Country code + number, e.g. 6591234567"))
            DatePicker("Today's appointments at", selection: timeBinding($todayMinutes, slot: .today),
                       displayedComponents: .hourAndMinute)
            DatePicker("Tomorrow's appointments at", selection: timeBinding($tomorrowMinutes, slot: .tomorrow),
                       displayedComponents: .hourAndMinute)
            Picker("Send via", selection: $deliveryRaw) {
                ForEach(WhatsAppDelivery.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Toggle("Skip days with no appointments", isOn: $skipEmptyDays)
            Toggle("Open Planner at login", isOn: $opensAtLogin)
                .onChange(of: opensAtLogin) { setOpensAtLogin(opensAtLogin) }
            HStack {
                Button("Send Today's Now") { Task { await reminders.send(.today) } }
                Button("Send Tomorrow's Now") { Task { await reminders.send(.tomorrow) } }
                if reminders.isSending { ProgressView().controlSize(.small) }
            }
            .disabled(reminders.isSending)
            if !reminders.lastStatus.isEmpty {
                Text(reminders.lastStatus)
                    .font(.caption)
                    .foregroundStyle(reminders.lastStatus.contains("failed") ? .orange : .green)
                    .textSelection(.enabled)
            }
            if let loginItemError {
                Text(loginItemError).font(.caption).foregroundStyle(.orange)
            }
            Text(deliveryRaw == WhatsAppDelivery.hermes.rawValue
                 ? "Sent automatically through Hermes's WhatsApp bridge. One-time setup in Terminal: run `hermes whatsapp`, scan the QR code with WhatsApp, then restart the gateway (`hermes gateway restart`). Planner must be running at the scheduled time (it can sit in the background); a reminder missed while the Mac slept is sent on wake if it's less than 4 hours late."
                 : "Opens WhatsApp with the reminder already typed — press Send. Needs no setup, but someone has to be at the Mac. Planner must be running at the scheduled time.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Bridges a minutes-after-midnight setting to a DatePicker's Date.
    private func timeBinding(_ minutes: Binding<Int>, slot: ReminderSlot) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.startOfDay(for: Date())
                    .addingTimeInterval(TimeInterval(minutes.wrappedValue * 60))
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                minutes.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
                reminders.timeDidChange(slot)
            })
    }

    private func setOpensAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
        } catch {
            loginItemError = "Couldn't change the login item: \(error.localizedDescription)"
            opensAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

#Preview {
    MacSettingsPane()
        .frame(width: 420, height: 300)
}
