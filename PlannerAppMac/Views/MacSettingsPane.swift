import SwiftUI

/// App settings, reachable from BOTH the sidebar (Support ▸ Settings) and the standard
/// macOS Settings window (Planner ▸ Settings…, ⌘,). One view so they never diverge.
struct MacSettingsPane: View {
    @AppStorage("terminalAgent") private var terminalAgentRaw = TerminalAgent.hermes.rawValue
    @AppStorage("hermesPanelVisible") private var hermesVisible = true

    var body: some View {
        Form {
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
