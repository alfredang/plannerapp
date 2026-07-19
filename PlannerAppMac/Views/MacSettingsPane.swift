import SwiftUI
import SwiftData

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

    var body: some View {
        Form {
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
}

#Preview {
    MacSettingsPane()
        .frame(width: 420, height: 300)
}
