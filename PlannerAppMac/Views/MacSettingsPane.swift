import SwiftUI

/// App settings, reachable from BOTH the sidebar (Support ▸ Settings) and the standard
/// macOS Settings window (Planner ▸ Settings…, ⌘,). One view so they never diverge.
struct MacSettingsPane: View {
    @AppStorage("terminalAgent") private var terminalAgentRaw = TerminalAgent.hermes.rawValue
    @AppStorage("hermesPanelVisible") private var hermesVisible = true
    /// Off by default — the agent archives instead of deleting, and cannot delete lists.
    @AppStorage(HermesBridge.allowsAgentDeletionKey) private var allowsAgentDeletion = false

    var body: some View {
        Form {
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
