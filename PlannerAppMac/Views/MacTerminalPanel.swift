import SwiftUI
import AppKit
import SwiftTerm

/// The agents the panel runs, one tab each. Which one is in front at launch is set in
/// Settings (⌘,); persisted via AppStorage.
enum TerminalAgent: String, CaseIterable, Identifiable {
    case claude, codex, hermes, openclaw

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude:   return "Claude Code"
        case .codex:    return "Codex"
        case .hermes:   return "Hermes Agent"
        case .openclaw: return "OpenClaw"
        }
    }

    /// The CLI to exec.
    var executable: String {
        switch self {
        case .claude:   return "claude"
        case .codex:    return "codex"
        case .hermes:   return "hermes"
        case .openclaw: return "openclaw"
        }
    }

    /// Arguments after the executable (e.g. `hermes chat`). Hermes preloads the Planner
    /// bridge skill, so it knows the planner:// commands whatever its working directory.
    var arguments: String {
        switch self {
        // The user's choice (matches their shell alias): no per-command permission prompts.
        case .claude:   return " --dangerously-skip-permissions"
        case .codex:    return ""
        case .hermes:
            let skillInstalled = FileManager.default.fileExists(atPath: HermesBridge.hermesSkillURL.path)
            return skillInstalled ? " chat -s \(HermesBridge.hermesSkillName)" : " chat"
        case .openclaw: return " tui"   // bare `openclaw` only prints its help
        }
    }

    /// How a relaunch picks the workspace's last conversation back up: a shell test that's
    /// true when there is one (run in the workspace), and the arguments that resume it.
    /// OpenClaw needs none — its TUI always reconnects to the gateway's "main" session.
    var resume: (test: String, arguments: String)? {
        switch self {
        case .claude:
            return (#"ls "$HOME/.claude/projects/$(printf %s "$PWD" | sed 's/[^A-Za-z0-9]/-/g')" 2>/dev/null | grep -q '\.jsonl$'"#,
                    " --continue")
        case .codex:
            // `resume --last` is limited to this directory; check a session started here exists.
            return (#"find "$HOME/.codex/sessions" -name 'rollout-*.jsonl' 2>/dev/null | sort -r | head -200 | while read -r f; do head -n1 "$f" | grep -qF "\"cwd\":\"$PWD\"" && echo found && break; done | grep -q found"#,
                    " resume --last")
        case .hermes:
            return ("true", " --continue")   // starts fresh by itself when there's nothing to continue
        case .openclaw:
            return nil
        }
    }

    /// Typed into the running agent to start a fresh conversation.
    var newSessionCommand: String {
        self == .claude ? "/clear" : "/new"
    }

    /// Typed into the running agent to browse and reopen earlier conversations.
    var historyCommand: String {
        switch self {
        case .claude, .codex:     return "/resume"
        case .hermes, .openclaw:  return "/sessions"
        }
    }
}

/// The agent panel's tabs: one per agent — all four started with the app and kept running —
/// plus browser tabs. Terminal processes live here in `TerminalSession`s, not in the SwiftUI
/// views, so hiding the panel or switching it between docked and overlay never restarts an
/// agent.
@MainActor
final class AgentPanelTabs: ObservableObject {
    static let shared = AgentPanelTabs()

    struct TerminalTab: Identifiable {
        var agent: TerminalAgent
        var id: TerminalAgent { agent }
        /// Bumping it replaces the tab's session, i.e. relaunches its process.
        var runID = UUID()
        /// Whether the next launch picks the last conversation back up.
        var resume = true
        var exited = false
    }

    @Published private(set) var terminals: [TerminalTab] = TerminalAgent.allCases.map { TerminalTab(agent: $0) }
    @Published private(set) var selectedTerminal: TerminalAgent =
        TerminalAgent(rawValue: UserDefaults.standard.string(forKey: "terminalAgent") ?? "") ?? .hermes
    /// The first browser tab is the reports browser (`AgentBrowser.shared`) and stays open.
    @Published private(set) var browsers: [AgentBrowser] = [AgentBrowser.shared]
    @Published private(set) var selectedBrowser: UUID = AgentBrowser.shared.id

    /// Running terminals by agent.
    private var sessions: [TerminalAgent: TerminalSession] = [:]

    /// The browser tab links open in: the one shown last.
    var currentBrowser: AgentBrowser { browsers.first { $0.id == selectedBrowser } ?? AgentBrowser.shared }
    var currentTerminal: TerminalTab? { terminals.first { $0.agent == selectedTerminal } }

    private func showKind(_ kind: String) { UserDefaults.standard.set(kind, forKey: AgentBrowser.tabKey) }

    /// Starts every agent that isn't running yet — called at launch so all four are ready
    /// (and keep listening) whether or not the panel is showing.
    func startAll() {
        for tab in terminals { _ = session(for: tab) }
    }

    /// The tab's terminal, reused for as long as the tab's run lasts.
    func session(for tab: TerminalTab) -> TerminalSession {
        if let session = sessions[tab.agent], session.runID == tab.runID { return session }
        sessions[tab.agent]?.terminate()
        let agent = tab.agent
        let session = TerminalSession(agent: agent, resume: tab.resume, runID: tab.runID) { [weak self] in
            self?.markExited(agent)
        }
        sessions[agent] = session
        return session
    }

    func selectTerminal(_ agent: TerminalAgent) {
        selectedTerminal = agent
        showKind("terminal")
    }

    /// Starts a fresh conversation in the agent on screen, using the agent's own command so
    /// the process keeps running. A stopped agent is relaunched fresh instead.
    func newSession(_ agent: TerminalAgent) {
        guard let tab = terminals.first(where: { $0.agent == agent }) else { return }
        if tab.exited { restart(agent, resume: false) } else { sessions[agent]?.typeCommand(agent.newSessionCommand) }
    }

    /// Opens the agent's own list of earlier conversations. A stopped agent is relaunched
    /// on its last conversation first.
    func showHistory(_ agent: TerminalAgent) {
        guard let tab = terminals.first(where: { $0.agent == agent }) else { return }
        if tab.exited { restart(agent, resume: true) } else { sessions[agent]?.typeCommand(agent.historyCommand) }
    }

    /// Relaunches the agent's process (only when it has stopped).
    func restart(_ agent: TerminalAgent, resume: Bool = true) {
        guard let index = terminals.firstIndex(where: { $0.agent == agent }) else { return }
        sessions.removeValue(forKey: agent)?.terminate()
        terminals[index].resume = resume
        terminals[index].exited = false
        terminals[index].runID = UUID()
        _ = session(for: terminals[index])
    }

    private func markExited(_ agent: TerminalAgent) {
        guard let index = terminals.firstIndex(where: { $0.agent == agent }) else { return }
        terminals[index].exited = true
    }

    // MARK: Browser tabs

    @discardableResult
    func newBrowser(_ url: URL? = nil) -> AgentBrowser {
        let browser = AgentBrowser.makeTab()
        browsers.append(browser)
        if let url { browser.open(url) } else { selectBrowser(browser) }
        return browser
    }

    func selectBrowser(_ browser: AgentBrowser) {
        selectedBrowser = browser.id
        showKind("browser")
    }

    func closeBrowser(_ browser: AgentBrowser) {
        guard browser !== AgentBrowser.shared, let index = browsers.firstIndex(where: { $0 === browser }) else { return }
        browsers.remove(at: index)
        browser.webView.stopLoading()
        if selectedBrowser == browser.id { selectedBrowser = browsers[min(index, browsers.count - 1)].id }
    }
}

/// The collapsible right-hand agent panel: a tab per agent — real pty-backed terminals
/// (SwiftTerm) running Claude Code, Codex, Hermes and OpenClaw (see `TerminalAgent`) in the
/// app's Hermes workspace — plus built-in browser tabs. Agents read `planner-state.json`
/// and edit the todo list through the `planner://` command scheme (see `HermesBridge`).
/// Falls back to a plain zsh if an agent's CLI isn't installed.
struct MacTerminalPanel: View {
    @Binding var isVisible: Bool

    /// The agent in front at launch. Shared with the Settings pane via UserDefaults.
    @AppStorage("terminalAgent") private var terminalAgentRaw = TerminalAgent.hermes.rawValue

    private var agent: TerminalAgent { TerminalAgent(rawValue: terminalAgentRaw) ?? .hermes }

    /// "terminal" or "browser" — which kind of tab is showing. Terminals stay alive (just
    /// hidden) while a browser tab is showing.
    @AppStorage(AgentBrowser.tabKey) private var tab = "terminal"
    private var showsBrowser: Bool { tab == "browser" }

    @ObservedObject private var tabs = AgentPanelTabs.shared

    private var processExited: Bool { tabs.currentTerminal?.exited ?? false }

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
                ForEach(tabs.terminals) { terminal in
                    let isSelected = terminal.agent == tabs.selectedTerminal
                    TerminalHost(session: tabs.session(for: terminal), isActive: isSelected && !showsBrowser)
                        .padding(.leading, 8)
                        .padding(.trailing, 8 - Self.scrollerInset)
                        .padding(.vertical, 6)
                        .id(terminal.runID)
                        .opacity(isSelected ? 1 : 0)
                        .allowsHitTesting(isSelected)
                }

                if processExited && !showsBrowser {
                    exitOverlay
                }

                if showsBrowser {
                    MacBrowserPanel(browser: tabs.currentBrowser)
                        .id(tabs.currentBrowser.id)
                }
            }
            .clipped()
            if !showsBrowser {
                Divider()
                footer
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        // Settings changed the agent in front: show its tab.
        .onChange(of: terminalAgentRaw) { tabs.selectTerminal(agent) }
    }

    private var header: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(tabs.terminals) { terminal in
                        PanelTabChip(
                            title: terminal.agent.title,
                            systemImage: "terminal.fill",
                            status: terminal.exited ? .red : .green,
                            isSelected: !showsBrowser && terminal.agent == tabs.selectedTerminal,
                            select: { tabs.selectTerminal(terminal.agent) },
                            close: nil)
                    }
                    ForEach(tabs.browsers) { browser in
                        BrowserTabChip(
                            browser: browser,
                            isSelected: showsBrowser && browser.id == tabs.selectedBrowser,
                            select: { tabs.selectBrowser(browser) },
                            close: browser === AgentBrowser.shared ? nil : { tabs.closeBrowser(browser) })
                    }
                    Button { tabs.newBrowser() } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("New browser tab")
                }
            }
            if showsBrowser {
                Button { tabs.currentBrowser.webView.reload() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Reload the page")
            }
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

    /// The agent tab's own controls: a fresh conversation, or its earlier ones.
    private var footer: some View {
        let current = tabs.selectedTerminal
        return HStack(spacing: 12) {
            Button { tabs.newSession(current) } label: {
                Label("New Session", systemImage: "square.and.pencil")
            }
            .help("Start a fresh \(current.title) conversation (\(current.newSessionCommand))")
            Button { tabs.showHistory(current) } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .help("Browse and reopen earlier \(current.title) conversations (\(current.historyCommand))")
            Text("Try: “add buy milk tomorrow”, “mark it done”")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private var exitOverlay: some View {
        VStack(spacing: 12) {
            Text("The agent session ended.")
                .foregroundStyle(.secondary)
            if let terminal = tabs.currentTerminal {
                Button("Restart \(terminal.agent.title)") { tabs.restart(terminal.agent) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }
}

/// One tab in the panel header: icon, title, optional status dot, and a close button.
private struct PanelTabChip: View {
    var title: String
    var systemImage: String
    var status: SwiftUI.Color? = nil
    var isSelected: Bool
    var select: () -> Void
    var close: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 10))
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 130, alignment: .leading)
            if let status {
                Circle().fill(status).frame(width: 6, height: 6)
            }
            if let close {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .opacity(isSelected || hovering ? 1 : 0)
                .help("Close tab")
            }
        }
        .foregroundStyle(isSelected ? Theme.accent : .secondary)
        .padding(.leading, 8)
        .padding(.trailing, close == nil ? 8 : 4)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Theme.accent.opacity(0.14) : SwiftUI.Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .help(title)
    }
}

/// A browser tab's chip, titled live from its page.
private struct BrowserTabChip: View {
    @ObservedObject var browser: AgentBrowser
    var isSelected: Bool
    var select: () -> Void
    var close: (() -> Void)?

    var body: some View {
        PanelTabChip(title: browser.tabTitle, systemImage: "globe",
                     isSelected: isSelected, select: select, close: close)
    }
}

/// Shows a tab's terminal. The terminal view belongs to its `TerminalSession`; this only
/// hosts it, so tearing the host down (panel hidden, docked ↔ overlay) leaves the agent
/// running and the next host picks the same view back up.
private struct TerminalHost: NSViewRepresentable {
    let session: TerminalSession
    /// The terminal on screen. Background terminals are hidden so they never take
    /// keystrokes or wheel events, but their processes keep running.
    var isActive: Bool

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        session.view.removeFromSuperview()
        session.view.frame = container.bounds
        session.view.autoresizingMask = [.width, .height]
        container.addSubview(session.view)
        session.setActive(isActive, refocus: true)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        session.setActive(isActive)
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        // Only let go of the view; another host may already have taken it.
        container.subviews.forEach { $0.removeFromSuperview() }
    }
}

/// One terminal: SwiftTerm's `LocalProcessTerminalView` running an agent (or a plain shell
/// as fallback) inside the Hermes workspace directory. Lives as long as its tab.
@MainActor
final class TerminalSession: NSObject, LocalProcessTerminalViewDelegate {
    let view = AgentTerminalView(frame: .zero)
    let runID: UUID
    private var onExit: (() -> Void)?
    private var linkRouter: LinkRoutingDelegate?
    private var wheelMonitor: Any?
    private var wasActive = false

    init(agent: TerminalAgent, resume: Bool, runID: UUID, onExit: @escaping () -> Void) {
        self.runID = runID
        self.onExit = onExit
        super.init()
        let terminal = view
        terminal.processDelegate = self
        // Route clicked links into the built-in browser instead of Safari.
        linkRouter = LinkRoutingDelegate(base: terminal)
        terminal.terminalDelegate = linkRouter
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak terminal] event in
            guard let terminal, event.window === terminal.window, !terminal.isHiddenOrHasHiddenAncestor,
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
        // when present (picking its last conversation back up when asked to and there is
        // one), else drop to a plain shell.
        let cli = agent.executable
        let resumeLine = resume ? agent.resume.map { "  if \($0.test); then exec \(cli)\(agent.arguments)\($0.arguments); fi\n" } ?? "" : ""
        let bootstrap = """
        cd '\(workspace)' 2>/dev/null || cd ~
        if command -v \(cli) >/dev/null 2>&1; then
        \(resumeLine)  exec \(cli)\(agent.arguments)
        else
          echo '\(cli) CLI not found (expected on PATH, e.g. ~/.local/bin/\(cli)).'
          echo 'Dropping into a plain shell:'
          exec /bin/zsh -i
        fi
        """
        terminal.startProcess(
            executable: "/bin/zsh",
            args: ["-l", "-c", bootstrap],
            environment: env.map { "\($0.key)=\($0.value)" }
        )
        watchExit(of: terminal.process.shellPid)
    }

    /// Types a slash command into the agent: clears whatever is half-typed (⌃U), enters the
    /// command, then presses Return a moment later — sent together, TUIs read the Return as
    /// part of a paste and insert a newline instead of submitting.
    func typeCommand(_ command: String) {
        view.send(txt: "\u{15}" + command)
        let view = view
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { view.send(txt: "\r") }
        setActive(true, refocus: true)
    }

    func setActive(_ active: Bool, refocus: Bool = false) {
        Self.hideScroller(in: view)
        view.isHidden = !active
        // Coming to the front: hand it the keyboard so typing goes to this agent.
        if active && (refocus || !wasActive) {
            let view = view
            DispatchQueue.main.async {
                guard !view.isHiddenOrHasHiddenAncestor else { return }
                view.window?.makeFirstResponder(view)
            }
        }
        wasActive = active
    }

    /// Ends the agent (tab closed or relaunched) without reporting it as an exit.
    func terminate() {
        onExit = nil
        if let monitor = wheelMonitor { NSEvent.removeMonitor(monitor) }
        wheelMonitor = nil
        let pid = view.process.shellPid
        view.terminate()
        view.removeFromSuperview()
        // terminate() only sends SIGTERM, which an interactive zsh and some TUIs (OpenClaw)
        // ignore. Hang up the whole pty session like closing a terminal window does, and
        // force it if it's still there shortly after.
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

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.reportExit() } }
    }

    /// SwiftTerm can miss the agent's exit: when the agent leaves a background process
    /// holding the pty (Codex's self-update starts an app-server daemon), it stops reading
    /// without telling its delegate, the agent stays a zombie and the panel looks alive
    /// but dead. Wait on the pid ourselves so the "session ended" overlay always shows.
    private func watchExit(of pid: pid_t) {
        guard pid > 0 else { return }
        Thread.detachNewThread { [weak self] in
            var status: Int32 = 0
            // Returns once it exits — or at once with ECHILD if SwiftTerm reaped it first.
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.reportExit() } }
        }
    }

    private func reportExit() {
        let report = onExit
        onExit = nil
        report?()
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}

/// SwiftTerm scrolls only its own scrollback on the wheel. Full-screen TUIs (Claude Code,
/// OpenClaw) keep their history themselves and ask for mouse reporting, so with mouse
/// reporting on, forward the wheel to the program as SGR wheel events — that's how the
/// user scrolls back through the conversation. In an alternate screen without mouse
/// reporting, send arrow keys (xterm's "alternate scroll"). Hold ⌥ for the local buffer.
final class AgentTerminalView: LocalProcessTerminalView {
    private var pendingLines: CGFloat = 0

    /// SwiftTerm pastes text only, so ⌘V with a screenshot on the clipboard did nothing.
    /// Agents pick images up from a file path in the prompt (OpenClaw and Claude Code
    /// attach it), so paste copied files as their paths and raw image data as a saved PNG's
    /// path. Plain text pastes as before.
    override func paste(_ sender: Any) {
        let pasteboard = NSPasteboard.general
        let files = (pasteboard.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !files.isEmpty {
            // Finder's text flavour is just the file name — use the full paths instead.
            pastePaths(files.map(\.path))
        } else if pasteboard.string(forType: .string) == nil, let path = Self.savePastedImage(from: pasteboard) {
            pastePaths([path])
        } else {
            super.paste(sender)
        }
    }

    private func pastePaths(_ paths: [String]) {
        // Escape spaces like Terminal.app does, so the path stays one token.
        let text = paths.map { $0.replacingOccurrences(of: " ", with: "\\ ") }.joined(separator: " ") + " "
        guard let terminal else { return }
        send(txt: terminal.bracketedPasteMode ? "\u{1b}[200~\(text)\u{1b}[201~" : text)
    }

    /// Writes the clipboard image to a PNG under the temp folder (a path without spaces, which
    /// OpenClaw's image-path detection needs) and returns its path.
    private static func savePastedImage(from pasteboard: NSPasteboard) -> String? {
        guard let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("planner-pastes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("paste-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(4)).png")
        do { try png.write(to: url) } catch { return nil }
        return url.path
    }

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
            Task { @MainActor in AgentPanelTabs.shared.currentBrowser.open(url) }
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
