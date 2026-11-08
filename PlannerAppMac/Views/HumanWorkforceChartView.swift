import SwiftUI
import WebKit

/// A Mac-only page the HR agent (Vesta) builds into the workspace and Planner shows in place of a
/// list: the Human Workforce org chart (`human-workforce.html`, from the HRMS) and the Trainer
/// Directory (`trainers.html`, from the LMS/TMS). They hold staff and trainer details, so they are
/// never synced or published. "⤢ Full screen" opens the page in a large window.
struct WorkspaceChartView: View {
    let fileURL: URL
    let windowTitle: String
    let emptyTitle: String
    let emptyHint: String

    init(fileName: String, windowTitle: String, emptyTitle: String, emptyHint: String) {
        self.init(fileURL: HermesBridge.workspaceURL.appendingPathComponent(fileName), windowTitle: windowTitle,
                  emptyTitle: emptyTitle, emptyHint: emptyHint)
    }

    init(fileURL: URL, windowTitle: String, emptyTitle: String, emptyHint: String) {
        self.fileURL = fileURL
        self.windowTitle = windowTitle
        self.emptyTitle = emptyTitle
        self.emptyHint = emptyHint
    }

    /// A person's (staff, intern or trainer) overview page for the Planner list named `listName`, from
    /// `<workspace>/people/index.json` ({list name: page path}), which the HR agent keeps. Mac only.
    static func personPage(forList listName: String) -> URL? {
        let index = HermesBridge.workspaceURL.appendingPathComponent("people/index.json")
        guard let data = try? Data(contentsOf: index),
              let map = try? JSONDecoder().decode([String: String].self, from: data),
              let path = map[listName], FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    var body: some View {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            HumanWorkforceWebView(fileURL: fileURL, windowTitle: windowTitle)
        } else {
            ContentUnavailableView {
                Label(emptyTitle, systemImage: "person.3")
            } description: {
                Text(emptyHint)
            }
        }
    }
}

extension WorkspaceChartView {
    static var humanWorkforce: WorkspaceChartView {
        WorkspaceChartView(fileName: "human-workforce.html", windowTitle: "Human Workforce Org Chart",
                           emptyTitle: "No org chart yet",
                           emptyHint: "Vesta builds it from the HRMS every morning. Run ~/DigitalWorkforce/bin/hr-sync.sh to build it now.")
    }

    static var trainers: WorkspaceChartView {
        WorkspaceChartView(fileName: "trainers.html", windowTitle: "Trainer Directory",
                           emptyTitle: "No trainer directory yet",
                           emptyHint: "Vesta builds it from the LMS/TMS every morning. Run ~/DigitalWorkforce/bin/trainers-sync.sh to build it now.")
    }
}

private struct HumanWorkforceWebView: NSViewRepresentable {
    let fileURL: URL
    let windowTitle: String

    func makeCoordinator() -> Coordinator { Coordinator(fileURL: fileURL, windowTitle: windowTitle) }

    func makeNSView(context: Context) -> WKWebView {
        let view = context.coordinator.makeWebView()
        view.setAccessibilityIdentifier("humanWorkforce.orgChart")
        context.coordinator.load(view, full: false)
        context.coordinator.mainView = view
        context.coordinator.startWatching()
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.reloadIfChanged()
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate {
        let fileURL: URL
        let windowTitle: String
        weak var mainView: WKWebView?
        private var zoomWindow: NSWindow?
        private weak var zoomView: WKWebView?
        private var loadedDate: Date?
        private var timer: Timer?

        init(fileURL: URL, windowTitle: String) { self.fileURL = fileURL; self.windowTitle = windowTitle }

        func makeWebView() -> WKWebView {
            let configuration = WKWebViewConfiguration()
            configuration.userContentController.add(self, name: "orgChart")
            let view = WKWebView(frame: .zero, configuration: configuration)
            view.navigationDelegate = self
            view.setValue(false, forKey: "drawsBackground")
            return view
        }

        private var modified: Date? {
            (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
        }

        func load(_ view: WKWebView, full: Bool) {
            var components = URLComponents(url: fileURL, resolvingAgainstBaseURL: false)
            components?.fragment = full ? "full" : nil
            view.loadFileURL(components?.url ?? fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
            loadedDate = modified
        }

        /// The HR agent rebuilds the file during the day: pick up a new version every 60 s.
        func startWatching() {
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.reloadIfChanged() }
        }

        func reloadIfChanged() {
            guard let date = modified, date != loadedDate else { return }
            if let mainView { load(mainView, full: false) }
            if let zoomView { load(zoomView, full: true) }
        }

        func stop() {
            timer?.invalidate()
            mainView?.configuration.userContentController.removeScriptMessageHandler(forName: "orgChart")
            zoomWindow?.close()
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: String], body["zoom"] != nil else { return }
            openZoomWindow()
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Local pages (the chart, people/ and trainer pages) open here; web links such as
            // "Open in HRMS" or a trainer's LinkedIn open in the default browser.
            let url = action.request.url
            switch url?.scheme {
            case "about":
                decisionHandler(.allow)
            case "file":
                // Pages (the chart, people/ and trainer pages) open here; a trainer's evidence folder,
                // a CV or a certificate PDF opens in Finder / Preview.
                let ext = url?.pathExtension.lowercased() ?? ""
                if ext == "html" || ext == "htm" || action.navigationType != .linkActivated {
                    decisionHandler(.allow)
                } else {
                    if let url { NSWorkspace.shared.open(url) }
                    decisionHandler(.cancel)
                }
            case "https", "http":
                if action.navigationType == .linkActivated, let url { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel)
            default:
                decisionHandler(.cancel)
            }
        }

        private func openZoomWindow() {
            if let zoomWindow { zoomWindow.makeKeyAndOrderFront(nil); return }
            let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: frame.width * 0.92, height: frame.height * 0.92),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = windowTitle
            window.isReleasedWhenClosed = false
            window.delegate = self
            let view = makeWebView()
            view.setAccessibilityIdentifier("humanWorkforce.orgChart.full")
            window.contentView = view
            load(view, full: true)
            window.center()
            window.makeKeyAndOrderFront(nil)
            zoomWindow = window
            zoomView = view
        }

        func windowWillClose(_ notification: Notification) {
            zoomView?.configuration.userContentController.removeScriptMessageHandler(forName: "orgChart")
            zoomView = nil
            zoomWindow = nil
        }
    }
}
