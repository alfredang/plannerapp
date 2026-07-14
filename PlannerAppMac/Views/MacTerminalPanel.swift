import SwiftUI
import AppKit
import SwiftTerm

/// The collapsible right-hand terminal panel: a real pty-backed terminal (SwiftTerm) that
/// auto-starts the user's `hermes` CLI agent in the app's Hermes workspace. From there the
/// agent reads `planner-state.json` and edits the todo list through the `planner://` command
/// scheme (see `HermesBridge`). Falls back to a plain zsh if hermes isn't installed.
struct MacTerminalPanel: View {
    @Binding var isVisible: Bool

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
                HermesTerminalView {
                    processExited = true
                }
                .padding(.leading, 8)
                .padding(.trailing, 8 - Self.scrollerInset)
                .padding(.vertical, 6)
                .id(runID)

                if processExited {
                    exitOverlay
                }
            }
            .clipped()
            Divider()
            footer
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.accent)
            Text("Hermes Agent")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Circle()
                .fill(processExited ? Color.red : Color.green)
                .frame(width: 7, height: 7)
                .accessibilityLabel(processExited ? "Agent stopped" : "Agent running")
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
            Button("Restart Hermes") { restart() }
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
    var onProcessExit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onProcessExit: onProcessExit) }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminal = LocalProcessTerminalView(frame: .zero)
        terminal.processDelegate = context.coordinator
        // 11pt keeps ~80 columns usable at the default panel width; SwiftTerm reflows on resize.
        terminal.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        terminal.nativeBackgroundColor = .black
        terminal.nativeForegroundColor = NSColor(calibratedWhite: 0.92, alpha: 1)
        Self.hideScroller(in: terminal)
        DispatchQueue.main.async { Self.hideScroller(in: terminal) }

        // Inherit the user's environment; make sure ~/.local/bin (hermes) is on PATH.
        var env = ProcessInfo.processInfo.environment
        let home = env["HOME"] ?? NSHomeDirectory()
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["PATH"] = "\(home)/.local/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")

        let workspace = HermesBridge.workspaceURL.path
        // Login shell so the user's own PATH additions apply too; exec hermes when present.
        let bootstrap = """
        cd '\(workspace)' 2>/dev/null || cd ~
        if command -v hermes >/dev/null 2>&1; then
          exec hermes chat
        else
          echo 'hermes CLI not found (expected on PATH, e.g. ~/.local/bin/hermes).'
          echo 'Install Hermes Agent, then click the restart button above.'
          echo 'Dropping into a plain shell:'
          exec /bin/zsh -i
        fi
        """
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

    /// SwiftTerm embeds an NSScroller with no public toggle — keep it hidden; scrollback
    /// still works with the trackpad/mouse wheel.
    private static func hideScroller(in view: NSView) {
        for sub in view.subviews where sub is NSScroller {
            sub.isHidden = true
        }
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let onProcessExit: () -> Void
        init(onProcessExit: @escaping () -> Void) { self.onProcessExit = onProcessExit }

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            DispatchQueue.main.async { self.onProcessExit() }
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    }
}

#Preview {
    MacTerminalPanel(isVisible: .constant(true))
        .frame(width: 420, height: 600)
}
