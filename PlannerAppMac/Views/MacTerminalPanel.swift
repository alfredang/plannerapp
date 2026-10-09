import SwiftUI
import AppKit
import SwiftTerm

/// What the terminal panel auto-starts. User-selectable in Settings (⌘,) and from the
/// panel header; persisted via AppStorage and synced between both places.
enum TerminalAgent: String, CaseIterable, Identifiable {
    case claude, codex, hermes, openclaw, blank

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude:   return "Claude"
        case .codex:    return "Codex"
        case .hermes:   return "Hermes"
        case .openclaw: return "OpenClaw"
        case .blank:    return "Blank terminal"
        }
    }

    /// Panel header title.
    var panelTitle: String {
        switch self {
        case .claude:   return "Claude Code"
        case .codex:    return "Codex"
        case .hermes:   return "Hermes Agent"
        case .openclaw: return "OpenClaw Agent"
        case .blank:    return "Terminal"
        }
    }

    /// The CLI to exec, or nil for a plain shell.
    var executable: String? {
        switch self {
        case .claude:   return "claude"
        case .codex:    return "codex"
        case .hermes:   return "hermes"
        case .openclaw: return "openclaw"
        case .blank:    return nil
        }
    }

    /// Arguments after the executable (e.g. `hermes chat`). Hermes preloads the Planner
    /// bridge skill, so it knows the planner:// commands whatever its working directory.
    var arguments: String {
        if self == .openclaw { return " tui" }   // bare `openclaw` only prints its help
        // The user's choice (matches their shell alias): no per-command permission prompts.
        if self == .claude { return " --dangerously-skip-permissions" }
        guard self == .hermes else { return "" }
        let skillInstalled = FileManager.default.fileExists(atPath: HermesBridge.hermesSkillURL.path)
        return skillInstalled ? " chat -s \(HermesBridge.hermesSkillName)" : " chat"
    }
}

/// The collapsible right-hand terminal panel: a real pty-backed terminal (SwiftTerm) that
/// auto-starts the user's chosen agent (Claude Code, Codex, Hermes, OpenClaw, or a plain
/// shell — see `TerminalAgent`) in the app's Hermes workspace. Agents read `planner-state.json` and edit
/// the todo list through the `planner://` command scheme (see `HermesBridge`). Falls back to
/// a plain zsh if the chosen CLI isn't installed.
struct MacTerminalPanel: View {
    @Binding var isVisible: Bool

    /// Which agent the terminal boots. Shared with the Settings pane via UserDefaults.
    @AppStorage("terminalAgent") private var terminalAgentRaw = TerminalAgent.hermes.rawValue

    private var agent: TerminalAgent { TerminalAgent(rawValue: terminalAgentRaw) ?? .hermes }

    /// "terminal" or "browser" — the built-in browser tab sits beside the terminal. The
    /// terminal stays alive (just hidden) while the browser is showing.
    @AppStorage(AgentBrowser.tabKey) private var tab = "terminal"
    private var showsBrowser: Bool { tab == "browser" }

    /// Bumping this recreates the terminal view, restarting the agent process.
    @State private var runID = UUID()
    @State private var processExited = false

    /// Width of the scroller strip SwiftTerm reserves at its right edge (legacy style —
    /// must match `scrollerStyle` in SwiftTerm's MacTerminalView).
    private static let scrollerInset = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                // Match the terminal's background so the breathing-room margin blends in.
                Color.black
                // SwiftTerm reserves `scrollerWidth` inside its right edge (its columns are
                // computed on width − scrollerWidth) and we hide that scroller — so push the
                // dead strip past the panel edge (clipped below) to keep the visible left and
                // right margins symmetric at 8pt.
                HermesTerminalView(agent: agent) {
                    processExited = true
                }
                .padding(.leading, 8)
                .padding(.trailing, 8 - Self.scrollerInset)
                .padding(.vertical, 6)
                .id(runID)

                if processExited {
                    exitOverlay
                }

                if showsBrowser {
                    MacBrowserPanel()
                }
            }
            .clipped()
            if !showsBrowser {
                Divider()
                footer
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: terminalAgentRaw) { restart() }   // switching agents reboots the terminal
    }

    private var header: some View {
        HStack(spacing: 6) {
            // Agent dropdown (also the Terminal tab), then the Browser tab. Clicking the
            // agent name shows the terminal; its chevron picks which agent the terminal runs.
            Menu {
                Picker("Terminal starts with", selection: $terminalAgentRaw) {
                    ForEach(TerminalAgent.allCases) { agent in
                        Text(agent.title).tag(agent.rawValue)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label(agent.panelTitle, systemImage: "terminal.fill")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            } primaryAction: {
                tab = "terminal"
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(tabBackground(!showsBrowser))
            .help("Terminal — click the arrow to choose the agent")
            Circle()
                .fill(processExited ? Color.red : Color.green)
                .frame(width: 7, height: 7)
                .accessibilityLabel(processExited ? "Agent stopped" : "Agent running")
            Button {
                tab = "browser"
            } label: {
                Label("Browser", systemImage: "globe")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(showsBrowser ? Theme.accent : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(tabBackground(showsBrowser))
            .help("Built-in browser — agent reports and links")
            Spacer(minLength: 4)
            Button {
                restart()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Restart the agent")
            Button {
                withAnimation { isVisible = false }
            } label: {
                Image(systemName: "sidebar.trailing")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Hide the agent panel (⌥⌘T)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func tabBackground(_ selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(selected ? Theme.accent.opacity(0.14) : Color.clear)
    }

    private var footer: some View {
        Text("Try: “add buy milk tomorrow”, “move the n8n task to AI-LMS-TMS”, “mark it done”")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
    }

    private var exitOverlay: some View {
        VStack(spacing: 12) {
            Text("The agent session ended.")
                .foregroundStyle(.secondary)
            Button("Restart \(agent.title)") { restart() }
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }

    private func restart() {
        processExited = false
        runID = UUID()
    }
}

/// AppKit bridge to SwiftTerm's `LocalProcessTerminalView`, launching the Hermes agent
/// (or a plain shell as fallback) inside the Hermes workspace directory.
private struct HermesTerminalView: NSViewRepresentable {
    var agent: TerminalAgent
    var onProcessExit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onProcessExit: onProcessExit) }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminal = AgentTerminalView(frame: .zero)
        terminal.processDelegate = context.coordinator
        // Route clicked links into the built-in browser instead of Safari.
        context.coordinator.linkRouter = LinkRoutingDelegate(base: terminal)
        terminal.terminalDelegate = context.coordinator.linkRouter
        context.coordinator.wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak terminal] event in
            guard let terminal, event.window === terminal.window,
                  UserDefaults.standard.string(forKey: AgentBrowser.tabKey) != "browser",
                  terminal.bounds.contains(terminal.convert(event.locationInWindow, from: nil))
            else { return event }
            return terminal.handleWheel(event) ? nil : event
        }
        // 11pt keeps ~80 columns usable at the default panel width; SwiftTerm reflows on resize.
        terminal.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        terminal.nativeBackgroundColor = .black
        terminal.nativeForegroundColor = NSColor(calibratedWhite: 0.92, alpha: 1)
        Self.hideScroller(in: terminal)
        DispatchQueue.main.async { Self.hideScroller(in: terminal) }

        // Inherit the user's environment; make sure the usual agent CLI homes are on PATH —
        // ~/.local/bin (claude, codex, hermes), ~/.openclaw/bin (the OpenClaw installer's
        // launcher — ahead of any stale npm/pnpm global copy, which rejects the config the
        // newer gateway writes), pnpm, Homebrew. A Dock launch
        // gets only launchd's minimal PATH, and `zsh -l` reads .zprofile but not .zshrc.
        // Drop session state inherited when Planner itself was launched from a Claude Code
        // (or VS Code) session: with CLAUDECODE / CLAUDE_CODE_* set, a `claude` started in
        // this terminal runs as a nested child of that session (stale version, no updates,
        // its effort/model, its messaging socket) instead of a normal top-level session.
        var env = ProcessInfo.processInfo.environment.filter { key, _ in
            !(key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") || key.hasPrefix("CLAUDE_AGENT_SDK")
              || key == "CLAUDE_PID" || key == "CLAUDE_EFFORT"
              || key.hasPrefix("VSCODE_") || key == "TERM_PROGRAM" || key == "TERM_PROGRAM_VERSION")
        }
        let home = env["HOME"] ?? NSHomeDirectory()
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        let agentDirs = ["\(home)/.local/bin", "\(home)/.openclaw/bin", "\(home)/Library/pnpm", "/opt/homebrew/bin", "/usr/local/bin"]
        env["PATH"] = (agentDirs + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")

        let workspace = HermesBridge.workspaceURL.path
        // Login shell so the user's own PATH additions apply too; exec the chosen agent
        // when present, else drop to a plain shell.
        let bootstrap: String
        if let cli = agent.executable {
            bootstrap = """
            cd '\(workspace)' 2>/dev/null || cd ~
            if command -v \(cli) >/dev/null 2>&1; then
              exec \(cli)\(agent.arguments)
            else
              echo '\(cli) CLI not found (expected on PATH, e.g. ~/.local/bin/\(cli)).'
              echo 'Install it, or pick another agent from the panel title / Settings (⌘,).'
              echo 'Dropping into a plain shell:'
              exec /bin/zsh -i
            fi
            """
        } else {
            bootstrap = """
            cd '\(workspace)' 2>/dev/null || cd ~
            exec /bin/zsh -i
            """
        }
        terminal.startProcess(
            executable: "/bin/zsh",
            args: ["-l", "-c", bootstrap],
            environment: env.map { "\($0.key)=\($0.value)" }
        )
        return terminal
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        Self.hideScroller(in: nsView)
    }

    /// SwiftUI can build this view more than once (e.g. the first layout pass picks the
    /// overlay layout, the next the docked one). End the discarded terminal's agent, or it
    /// keeps running unseen — a second Hermes listening alongside the visible one.
    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        coordinator.isDismantled = true
        if let monitor = coordinator.wheelMonitor { NSEvent.removeMonitor(monitor) }
        let pid = nsView.process.shellPid
        nsView.terminate()
        // terminate() only sends SIGTERM, which an interactive zsh and some TUIs (OpenClaw)
        // ignore — the hidden copy then lives on. Hang up the whole pty session like closing
        // a terminal window does, and force it if it's still there shortly after.
        guard pid > 0 else { return }
        killpg(pid, SIGHUP)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if kill(pid, 0) == 0 { killpg(pid, SIGKILL) }
        }
    }

    /// SwiftTerm embeds an NSScroller with no public toggle — keep it hidden; scrollback
    /// still works with the trackpad/mouse wheel.
    private static func hideScroller(in view: NSView) {
        for sub in view.subviews where sub is NSScroller {
            sub.isHidden = true
        }
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let onProcessExit: () -> Void
        /// Set when SwiftUI tears this terminal down, so its exit isn't reported as the
        /// visible terminal's.
        var isDismantled = false
        var linkRouter: LinkRoutingDelegate?
        var wheelMonitor: Any?
        init(onProcessExit: @escaping () -> Void) { self.onProcessExit = onProcessExit }

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            DispatchQueue.main.async {
                if !self.isDismantled { self.onProcessExit() }
            }
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    }
}

/// SwiftTerm scrolls only its own scrollback on the wheel. Full-screen TUIs (Claude Code,
/// OpenClaw) keep their history themselves and ask for mouse reporting, so with mouse
/// reporting on, forward the wheel to the program as SGR wheel events — that's how the
/// user scrolls back through the conversation. In an alternate screen without mouse
/// reporting, send arrow keys (xterm's "alternate scroll"). Hold ⌥ for the local buffer.
final class AgentTerminalView: LocalProcessTerminalView {
    private var pendingLines: CGFloat = 0

    /// Handles a wheel event over this view; false = leave it to SwiftTerm's own scrolling.
    /// (SwiftTerm's `scrollWheel` isn't `open`, so an event monitor calls this instead.)
    func handleWheel(_ event: NSEvent) -> Bool {
        guard let terminal, !event.modifierFlags.contains(.option),
              terminal.mouseMode != .off || terminal.isCurrentBufferAlternate else {
            return false
        }
        // Trackpads report pixels in small steps; accumulate them into whole lines.
        pendingLines += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 12 : event.scrollingDeltaY
        let lines = Int(pendingLines.rounded(.towardZero))
        guard lines != 0 else { return true }
        pendingLines -= CGFloat(lines)
        let up = lines > 0
        let count = min(abs(lines), 10)

        if terminal.mouseMode != .off && allowMouseReporting {
            let point = convert(event.locationInWindow, from: nil)
            let col = max(0, min(terminal.cols - 1, Int(point.x / max(bounds.width, 1) * CGFloat(terminal.cols))))
            let row = max(0, min(terminal.rows - 1,
                                 Int((bounds.height - point.y) / max(bounds.height, 1) * CGFloat(terminal.rows))))
            let flags = terminal.encodeButton(button: up ? 4 : 5, release: false,
                                              shift: false, meta: false, control: false)
            for _ in 0..<count { terminal.sendEvent(buttonFlags: flags, x: col, y: row) }
        } else {
            let key = terminal.applicationCursor ? (up ? "\u{1b}OA" : "\u{1b}OB") : (up ? "\u{1b}[A" : "\u{1b}[B")
            for _ in 0..<count { send(txt: key) }
        }
        return true
    }
}

/// Stands in as the terminal's delegate to open links in the built-in browser, and forwards
/// everything else to the terminal view's own handling (input, resize, clipboard…).
final class LinkRoutingDelegate: TerminalViewDelegate {
    weak var base: LocalProcessTerminalView?
    init(base: LocalProcessTerminalView) { self.base = base }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        let fixed = link.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? link
        guard let url = URL(string: link) ?? URL(string: fixed) else { return }
        if url.scheme == "http" || url.scheme == "https" || url.isFileURL {
            Task { @MainActor in AgentBrowser.shared.open(url) }
        } else {
            NSWorkspace.shared.open(url)
        }
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        base?.sizeChanged(source: source, newCols: newCols, newRows: newRows)
    }
    func setTerminalTitle(source: TerminalView, title: String) { base?.setTerminalTitle(source: source, title: title) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        base?.hostCurrentDirectoryUpdate(source: source, directory: directory)
    }
    func send(source: TerminalView, data: ArraySlice<UInt8>) { base?.send(source: source, data: data) }
    func scrolled(source: TerminalView, position: Double) { base?.scrolled(source: source, position: position) }
    func clipboardCopy(source: TerminalView, content: Data) { base?.clipboardCopy(source: source, content: content) }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        base?.rangeChanged(source: source, startY: startY, endY: endY)
    }
}

#Preview {
    MacTerminalPanel(isVisible: .constant(true))
        .frame(width: 420, height: 600)
}
