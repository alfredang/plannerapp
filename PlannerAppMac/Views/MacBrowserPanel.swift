import SwiftUI
import AppKit
import WebKit
import UniformTypeIdentifiers

/// The agent panel's built-in browser. One long-lived web view shared by the Browser tab,
/// links clicked in the terminal, and the agents' `planner://browse` command — so agent
/// reports (self-contained HTML pages) and claude.ai artifacts open right next to the chat.
@MainActor
final class AgentBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    static let shared = AgentBrowser()

    /// Which tab the agent panel shows ("terminal" / "browser"). AppStorage-backed, so
    /// `open(_:)` can bring the browser forward from anywhere.
    nonisolated static let tabKey = "agentPanelTab"

    /// Where agents drop report pages, plus an optional `index.json` manifest (newest first).
    nonisolated static var reportsURL: URL { HermesBridge.workspaceURL.appendingPathComponent("reports", isDirectory: true) }

    let webView: WKWebView
    @Published var addressText = ""
    @Published var pageTitle = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published private(set) var hasPage = false
    @Published private(set) var reports: [Report] = []

    struct Report: Identifiable, Decodable {
        var file: String
        var title: String?
        var agent: String?
        var date: String?
        var summary: String?
        var url: String?
        var modified: Int?
        var id: String { file }
        var displayTitle: String { title ?? file.replacingOccurrences(of: ".html", with: "") }
    }

    private var observations: [NSKeyValueObservation] = []
    private var folderWatch: DispatchSourceFileSystemObject?

    private override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // persistent: a claude.ai sign-in sticks
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        // Present as Safari so sign-in pages (claude.ai, Google) don't reject an embedded view.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        observations = [
            webView.observe(\.canGoBack) { [weak self] v, _ in Task { @MainActor in self?.canGoBack = v.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] v, _ in Task { @MainActor in self?.canGoForward = v.canGoForward } },
            webView.observe(\.isLoading) { [weak self] v, _ in Task { @MainActor in self?.isLoading = v.isLoading } },
            webView.observe(\.title) { [weak self] v, _ in Task { @MainActor in self?.pageTitle = v.title ?? "" } },
            webView.observe(\.url) { [weak self] v, _ in
                Task { @MainActor in
                    guard let self, let url = v.url else { return }
                    self.hasPage = true
                    self.addressText = url.isFileURL ? url.path : url.absoluteString
                }
            },
        ]
        try? FileManager.default.createDirectory(at: Self.reportsURL, withIntermediateDirectories: true)
        reloadReports()
        watchReportsFolder()
    }

    // MARK: - Opening

    /// Opens a URL (web or file) and brings the Browser tab forward.
    func open(_ url: URL) {
        UserDefaults.standard.set("browser", forKey: Self.tabKey)
        if url.isFileURL {
            // Agent reports are often HTML fragments with no <meta charset>; WebKit then
            // reads local files as Latin-1 and emoji/dashes turn into "ðŸ…" mojibake.
            // Load those as UTF-8 explicitly.
            if ["html", "htm"].contains(url.pathExtension.lowercased()),
               let data = try? Data(contentsOf: url),
               !String(decoding: data.prefix(2048), as: UTF8.self).lowercased().contains("charset") {
                webView.load(data, mimeType: "text/html", characterEncodingName: "utf-8", baseURL: url)
            } else {
                webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            }
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    func open(report: Report) {
        open(Self.reportsURL.appendingPathComponent(report.file))
    }

    /// Address-bar input: a path (/…, ~/…), a URL, or a bare host.
    func open(typed raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if text.hasPrefix("/") || text.hasPrefix("~") {
            open(URL(fileURLWithPath: (text as NSString).expandingTildeInPath))
        } else if let url = URL(string: text), url.scheme != nil {
            open(url)
        } else if let url = URL(string: "https://" + text) {
            open(url)
        }
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html, .pdf, .plainText, .image]
        panel.directoryURL = Self.reportsURL
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    // MARK: - Reports list

    /// From `index.json` when the agents keep one; otherwise the folder's HTML files,
    /// newest first.
    func reloadReports() {
        let dir = Self.reportsURL
        if let data = try? Data(contentsOf: dir.appendingPathComponent("index.json")),
           let list = try? JSONDecoder().decode([Report].self, from: data) {
            reports = list.filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.file).path) }
            return
        }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        reports = files
            .filter { $0.pathExtension.lowercased() == "html" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
            .map { Report(file: $0.lastPathComponent) }
    }

    private func watchReportsFolder() {
        let fd = Darwin.open(Self.reportsURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            // Agents write the page and then the manifest; settle briefly before re-reading.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.reloadReports() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        folderWatch = source
    }

    // MARK: - WKUIDelegate

    /// target="_blank" links open in this same view rather than vanishing.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }
}

/// The Browser tab: a compact toolbar over the shared web view, with the agents' reports
/// one click away.
struct MacBrowserPanel: View {
    @ObservedObject private var browser = AgentBrowser.shared

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ZStack {
                BrowserWebView(webView: browser.webView)
                if !browser.hasPage { emptyState }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))   // cover the terminal behind
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button { browser.webView.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!browser.canGoBack).help("Back")
            Button { browser.webView.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!browser.canGoForward).help("Forward")
            Button {
                if browser.isLoading { browser.webView.stopLoading() } else { browser.webView.reload() }
            } label: { Image(systemName: browser.isLoading ? "xmark" : "arrow.clockwise") }
                .help(browser.isLoading ? "Stop" : "Reload")
            TextField("Search or enter a URL or file path", text: $browser.addressText)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onSubmit { browser.open(typed: browser.addressText) }
            reportsMenu
            Button {
                if let url = browser.webView.url { NSWorkspace.shared.open(url) }
            } label: { Image(systemName: "safari") }
                .disabled(!browser.hasPage).help("Open in Safari")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private var reportsMenu: some View {
        Menu {
            if browser.reports.isEmpty {
                Text("No reports yet")
            }
            ForEach(browser.reports.prefix(30)) { report in
                Button(report.date.map { "\(report.displayTitle) — \($0)" } ?? report.displayTitle) {
                    browser.open(report: report)
                }
            }
            Divider()
            Button("Open File…") { browser.chooseFile() }
            Button("Show Reports Folder") { NSWorkspace.shared.open(AgentBrowser.reportsURL) }
        } label: {
            Image(systemName: "doc.richtext")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Agent reports")
    }

    private var emptyState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Reports")
                    .font(.headline)
                if browser.reports.isEmpty {
                    Text("Reports your agents publish appear here. Links you click in the terminal open in this tab too.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(browser.reports.prefix(20)) { report in
                    Button { browser.open(report: report) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(report.displayTitle).font(.callout.weight(.semibold))
                            if let line = [report.agent, report.date].compactMap({ $0 }).joined(separator: " · ").nonEmpty {
                                Text(line).font(.caption).foregroundStyle(.secondary)
                            }
                            if let summary = report.summary {
                                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// Hosts the shared WKWebView. The view outlives tab switches (it's owned by `AgentBrowser`).
private struct BrowserWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
