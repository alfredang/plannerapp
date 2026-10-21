import SwiftUI
import AppKit
import WebKit

/// Which agent's web dashboard Sidebar ▸ Dashboard shows.
enum DashboardAgent: String, CaseIterable, Identifiable {
    case hermes, openclaw
    var id: String { rawValue }

    var title: String {
        switch self {
        case .hermes:   return "Hermes"
        case .openclaw: return "OpenClaw"
        }
    }
}

/// One agent's dashboard: a long-lived web view plus the work of finding (and, for Hermes,
/// starting) the local server behind it. Held by `shared` so switching between the two, or
/// leaving the pane, never reloads a page the user was in the middle of.
@MainActor
final class AgentDashboard: ObservableObject {
    static let shared: [DashboardAgent: AgentDashboard] = [
        .hermes: AgentDashboard(.hermes),
        .openclaw: AgentDashboard(.openclaw),
    ]

    enum Status: Equatable {
        case idle, starting(String), ready, failed(String)
    }

    let agent: DashboardAgent
    let webView: WKWebView
    @Published private(set) var status: Status = .idle
    private var loadedURL: URL?

    private static let home = FileManager.default.homeDirectoryForCurrentUser.path
    /// `hermes dashboard`'s default port. The Digital Workforce watchdog keeps a server here
    /// too (it backs the daily video crons' monitoring), so usually it's already up.
    private static let hermesURL = URL(string: "http://127.0.0.1:9119/")!

    private init(_ agent: DashboardAgent) {
        self.agent = agent
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
    }

    /// Loads the dashboard once; later calls only retry after a failure.
    func loadIfNeeded() {
        switch status {
        case .ready, .starting: return
        case .idle, .failed: Task { await connect() }
        }
    }

    func reload() {
        if case .ready = status { webView.reload() } else { Task { await connect() } }
    }

    func openInBrowser() {
        if let url = webView.url ?? loadedURL { NSWorkspace.shared.open(url) }
    }

    private func connect() async {
        switch agent {
        case .hermes:
            if await Self.isUp(Self.hermesURL) { return show(Self.hermesURL) }
            status = .starting("Starting the Hermes dashboard…")
            Self.launch("'\(Self.home)/.local/bin/hermes' dashboard --no-open --skip-build --port 9119",
                        log: "\(Self.home)/DigitalWorkforce/logs/hermes-dashboard.log")
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if await Self.isUp(Self.hermesURL) { return show(Self.hermesURL) }
            }
            status = .failed("The Hermes dashboard didn't start. Run `hermes dashboard` in the Hermes tab to see why.")
        case .openclaw:
            status = .starting("Connecting to the OpenClaw gateway…")
            // `openclaw dashboard --json` prints the Control UI URL with a fresh login token.
            // Absolute path: ~/Library/pnpm/openclaw is a stale copy that rejects the config.
            let output = await Self.run("'\(Self.home)/.openclaw/bin/openclaw' dashboard --json --no-open")
            guard let data = output.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["ok"] as? Bool == true,
                  let raw = (json["url"] ?? json["browserUrl"]) as? String,
                  let url = URL(string: raw) else {
                status = .failed("The OpenClaw gateway isn't reachable. Start it with `openclaw gateway start`.")
                return
            }
            show(url)
        }
    }

    private func show(_ url: URL) {
        loadedURL = url
        webView.load(URLRequest(url: url))
        status = .ready
    }

    private static func isUp(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// The agent CLIs live in ~/.local/bin and ~/.openclaw/bin, which a GUI app's PATH lacks.
    private static func shell(_ command: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ["\(home)/.openclaw/bin", "\(home)/.local/bin", "/opt/homebrew/bin",
                       env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"].joined(separator: ":")
        env["HERMES_NO_UPDATE_WARN"] = "1"
        process.environment = env
        process.currentDirectoryURL = URL(fileURLWithPath: home)
        return process
    }

    /// Starts a server that outlives the app (nohup), so quitting Planner keeps it running.
    private static func launch(_ command: String, log: String) {
        let process = shell("nohup \(command) >> '\(log)' 2>&1 &")
        try? process.run()
    }

    private static func run(_ command: String) async -> String {
        await withCheckedContinuation { continuation in
            let process = shell(command)
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
            do { try process.run() } catch { continuation.resume(returning: "") }
        }
    }
}

/// Sidebar ▸ Dashboard: the Hermes Agent dashboard (cron jobs, sessions, config) or the
/// OpenClaw Control UI, embedded so the video crons and agent health are one click away.
struct MacDashboardPane: View {
    @AppStorage("dashboardAgent") private var agentRaw = DashboardAgent.hermes.rawValue

    private var agent: DashboardAgent { DashboardAgent(rawValue: agentRaw) ?? .hermes }

    var body: some View {
        DashboardView(dashboard: AgentDashboard.shared[agent]!)
            .id(agent)
            .navigationTitle("Dashboard")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Dashboard", selection: $agentRaw) {
                        ForEach(DashboardAgent.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
                ToolbarItemGroup {
                    Button { AgentDashboard.shared[agent]?.reload() } label: {
                        Label("Reload", systemImage: "arrow.clockwise")
                    }
                    .help("Reload the \(agent.title) dashboard")
                    Button { AgentDashboard.shared[agent]?.openInBrowser() } label: {
                        Label("Open in Browser", systemImage: "safari")
                    }
                    .help("Open the \(agent.title) dashboard in your browser")
                }
            }
    }
}

private struct DashboardView: View {
    @ObservedObject var dashboard: AgentDashboard

    var body: some View {
        ZStack {
            DashboardWebView(webView: dashboard.webView)
                .opacity(dashboard.status == .ready ? 1 : 0)
            switch dashboard.status {
            case .idle, .ready:
                EmptyView()
            case .starting(let message):
                VStack(spacing: 10) {
                    ProgressView()
                    Text(message).foregroundStyle(.secondary)
                }
            case .failed(let message):
                ContentUnavailableView {
                    Label("\(dashboard.agent.title) dashboard unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { dashboard.reload() }
                }
            }
        }
        .onAppear { dashboard.loadIfNeeded() }
    }
}

/// Hosts the dashboard's WKWebView, which outlives this view (it's owned by `AgentDashboard`).
private struct DashboardWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
