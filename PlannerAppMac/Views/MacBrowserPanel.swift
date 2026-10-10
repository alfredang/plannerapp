import SwiftUI
import AppKit
import WebKit
import UniformTypeIdentifiers

/// The agent panel's built-in browser. One long-lived web view shared by the Browser tab,
/// links clicked in the terminal, and the agents' `planner://browse` command — so agent
/// reports (self-contained HTML pages) and claude.ai artifacts open right next to the chat.
@MainActor
final class AgentBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
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
        // Reply boxes on report cards: the page script posts Alfred's answer here and the
        // agents read it back on their next run (see `saveReply`).
        config.userContentController.addUserScript(
            WKUserScript(source: Self.replyScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        config.userContentController.add(ReplyHandlerProxy(self), name: "reply")
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

    // MARK: - Replies to the agents

    /// One JSON object per line: {ts, page, item, text}. The Digital Workforce agents read
    /// this file at the start of every run and treat it as Alfred's answers.
    nonisolated static var repliesURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("DigitalWorkforce/replies/replies.jsonl")
    }

    private func savedReplies(forPage page: String) -> [[String: String]] {
        guard let text = try? String(contentsOf: Self.repliesURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String],
                  obj["page"] == page else { return nil }
            return obj
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url, url.isFileURL, url.pathExtension.lowercased() == "html",
              let data = try? JSONSerialization.data(withJSONObject: savedReplies(forPage: url.lastPathComponent)),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("if (window.__plShow) window.__plShow(\(json));")
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: String],
              let page = body["page"], let item = body["item"],
              let text = body["text"]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        let record: [String: String] = [
            "ts": ISO8601DateFormatter().string(from: Date()), "page": page, "item": item, "text": text,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        let url = Self.repliesURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); handle.write(Data("\n".utf8)); try? handle.close()
        } else {
            try? (data + Data("\n".utf8)).write(to: url)
        }
    }

    /// Adds a "Reply" box under every card (`.item`) of a report page.
    private static let replyScript = """
    (function () {
      if (!location.pathname.endsWith('.html') || location.protocol !== 'file:') return;
      var page = location.pathname.split('/').pop();
      var st = document.createElement('style');
      st.textContent = '.pl-reply{grid-column:2;font:13px -apple-system,sans-serif;margin:0}.pl-link{color:#3949c8;cursor:pointer;font-weight:600;font-size:12px;background:none;border:0;padding:0}.pl-form{display:none;gap:6px;margin-top:4px}.pl-form.open{display:flex}.pl-form input{flex:1;min-width:0;padding:4px 8px;border:1px solid #c9ced6;border-radius:6px;font:inherit}.pl-form button{padding:4px 12px;border:0;border-radius:6px;background:#3949c8;color:#fff;font:600 12px -apple-system,sans-serif;cursor:pointer}.pl-saved{margin-top:3px;padding:3px 8px;border-radius:6px;background:#e8f4ec;color:#1d5c34;font-size:12px;white-space:pre-wrap}';
      document.head.appendChild(st);
      function key(el) { return (el.innerText || '').replace(/\\s+/g, ' ').trim().slice(0, 90); }
      window.__plShow = function (saved) {
        document.querySelectorAll('.item').forEach(function (el) {
          if (el.querySelector('.pl-reply') || el.closest('.exec')) return;
          var k = key(el), box = document.createElement('div'); box.className = 'pl-reply';
          var link = document.createElement('button'); link.className = 'pl-link'; link.textContent = '💬 Reply';
          var form = document.createElement('div'); form.className = 'pl-form';
          var ta = document.createElement('input'); ta.placeholder = 'Reply to the agents…';
          var btn = document.createElement('button'); btn.textContent = 'Send';
          var out = document.createElement('div');
          link.onclick = function () { form.classList.toggle('open'); if (form.classList.contains('open')) ta.focus(); };
          function note(t) { var d = document.createElement('div'); d.className = 'pl-saved'; d.textContent = '✓ You: ' + t; out.appendChild(d); }
          saved.filter(function (r) { return r.item === k; }).forEach(function (r) { note(r.text); });
          function send() {
            var t = ta.value.trim(); if (!t) return;
            window.webkit.messageHandlers.reply.postMessage({ page: page, item: k, text: t });
            note(t); ta.value = ''; form.classList.remove('open');
          }
          btn.onclick = send;
          ta.onkeydown = function (e) { if (e.key === 'Enter') send(); };
          form.appendChild(ta); form.appendChild(btn);
          box.appendChild(out); box.appendChild(link); box.appendChild(form); el.appendChild(box);
        });
      };
    })();
    """

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


/// WKUserContentController retains its handlers; this keeps the browser from retaining itself.
private final class ReplyHandlerProxy: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}
