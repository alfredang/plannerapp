import SwiftUI
import WebKit

/// A self-contained, interactive version of the workforce artifact. Only a roster ID crosses
/// the web/native boundary; conversations and agent execution remain in the native chat view.
struct DigitalWorkforceArtifactView: NSViewRepresentable {
    let chart: OrgNode
    let jobs: [ScheduledJob]
    var onOpenAgent: (String) -> Void
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator(onOpenAgent: onOpenAgent) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "staffChat")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.setAccessibilityIdentifier("workforce.orgChart")
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onOpenAgent = onOpenAgent
        context.coordinator.allowedIDs = chart.descendantIDs.intersection(AgentRoster.staffIDs)
        let html = WorkforceArtifactHTML.render(chart: chart, jobs: jobs, dark: colorScheme == .dark)
        guard context.coordinator.html != html else { return }
        context.coordinator.html = html
        view.loadHTMLString(html, baseURL: nil)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "staffChat")
        view.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var onOpenAgent: (String) -> Void
        var allowedIDs: Set<String> = []
        var html = ""
        init(onOpenAgent: @escaping (String) -> Void) { self.onOpenAgent = onOpenAgent }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame,
                  let body = message.body as? [String: String],
                  let id = body["id"], allowedIDs.contains(id) else { return }
            onOpenAgent(id)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // This artifact has no remote content or navigable links.
            decisionHandler(action.request.url?.scheme == "about" ? .allow : .cancel)
        }
    }
}

enum WorkforceArtifactHTML {
    static func render(chart: OrgNode, jobs: [ScheduledJob], dark: Bool) -> String {
        let atlas = chart.children.first { $0.id == "atlas" }
        let staff = atlas?.children.filter { AgentRoster.staffIDs.contains($0.id) } ?? []
        let leads = chart.children.map { card($0, manager: chart.name, jobs: jobs) }.joined()
        let team = staff.map { card($0, manager: "Atlas", jobs: jobs) }.joined()
        let background = dark ? "#171b21" : "#f4f5f7"
        let surface = dark ? "#242a33" : "#ffffff"
        let foreground = dark ? "#eef1f5" : "#202833"
        let secondary = dark ? "#b9c4ce" : "#5c6974"
        let border = dark ? "#44505c" : "#d6dbe0"
        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline';">
        <title>Digital Workforce Org Chart</title>
        <style>
        :root{color-scheme:\(dark ? "dark" : "light");--bg:\(background);--surface:\(surface);--text:\(foreground);--muted:\(secondary);--border:\(border);--accent:\(dark ? "#a8d9d7" : "#376b69")}
        *{box-sizing:border-box}body{margin:0;padding:26px;background:var(--bg);color:var(--text);font:14px/1.5 -apple-system,BlinkMacSystemFont,sans-serif}
        main{max-width:1120px;margin:auto}h1{font:700 clamp(25px,3.8vw,38px)/1.15 Georgia,serif;margin:0 0 10px}header p{color:var(--muted);margin:0 0 8px;max-width:760px}
        .hint{font-size:13px}.principal{max-width:370px;margin:26px auto 0;padding:16px;text-align:center;border:1px solid \(dark ? "#9b835a" : "#c7ac82");background:\(dark ? "#3c3225" : "#f4e8d2");border-radius:9px}
        .principal h2{font:700 21px Georgia,serif;margin:0 0 3px}.principal p{margin:0;font-size:12px;color:\(dark ? "#e2c99f" : "#865e2f");text-transform:uppercase;letter-spacing:.06em}
        .line{height:28px;width:1px;background:var(--border);margin:auto}.reporting{text-align:center;color:var(--muted);font-size:11px;letter-spacing:.1em;text-transform:uppercase;margin:0 0 10px}
        .grid{display:grid;gap:12px;grid-template-columns:repeat(3,minmax(0,1fr))}.team{grid-template-columns:repeat(3,minmax(0,1fr))}
        .staff{display:flex;flex-direction:column;align-items:stretch;gap:8px;text-align:left;width:100%;padding:15px;background:var(--surface);color:var(--text);border:1px solid var(--border);border-top:3px solid var(--accent);border-radius:8px;cursor:pointer;font:inherit;transition:transform .12s,border-color .12s}
        .staff:hover{transform:translateY(-2px);border-color:var(--accent)}.staff:focus-visible{outline:3px solid var(--accent);outline-offset:3px}.staff h2{font:700 20px Georgia,serif;margin:0}.heading{display:flex;align-items:center;justify-content:space-between;gap:8px;flex-wrap:wrap}.model{font:10px ui-monospace,monospace;color:var(--accent);padding:3px 6px;border-radius:4px;background:\(dark ? "#203d3c" : "#e4f0ee")}
        .role{font-size:11px;text-transform:uppercase;letter-spacing:.06em;color:var(--accent);font-weight:650}.summary{font-size:12px;display:-webkit-box;-webkit-line-clamp:3;-webkit-box-orient:vertical;overflow:hidden}.facts{color:var(--muted);font:11px/1.6 ui-monospace,monospace}.chat{margin-top:auto;padding-top:5px;color:var(--accent);font-size:12px;font-weight:600}.footer{padding-top:20px;color:var(--muted);font-size:12px}
        @media(max-width:640px){body{padding:18px}.grid,.team{grid-template-columns:repeat(2,minmax(0,1fr))}.staff{padding:12px}}
        @media(max-width:420px){.grid,.team{grid-template-columns:1fr}}
        @media(prefers-reduced-motion:reduce){.staff{transition:none}.staff:hover{transform:none}}
        </style></head><body><main>
        <header><h1>Digital Workforce Org Chart</h1>
        <p>Nine AI staff working for \(escape(chart.name)). Planner is the master schedule; agents propose, Alfred decides.</p>
        <p class="hint">Select any staff card to ask a question and continue your conversation.</p></header>
        <section class="principal" aria-label="Principal"><h2>\(escape(chart.name))</h2><p>\(escape(chart.title))</p></section>
        <div class="line" aria-hidden="true"></div><p class="reporting">Reports directly to \(escape(chart.name))</p>
        <section class="grid" aria-label="Direct reports">\(leads)</section>
        <div class="line" aria-hidden="true"></div><p class="reporting">Reports to Atlas</p>
        <section class="grid team" aria-label="Staff reporting to Atlas">\(team)</section>
        <footer class="footer">Each staff member has a separate saved chat. Specialist helpers support their assigned lead.</footer>
        </main><script>
        document.querySelectorAll('[data-agent]').forEach(function(button){
          button.addEventListener('click',function(){window.webkit.messageHandlers.staffChat.postMessage({id:button.dataset.agent});});
        });
        </script></body></html>
        """
    }

    private static func card(_ node: OrgNode, manager: String, jobs: [ScheduledJob]) -> String {
        guard let agent = node.agent else { return "" }
        let scheduled = jobs.filter { $0.detail?.lowercased() == agent.id }.map(\.schedule).joined(separator: " · ")
        let summary = agent.summary.isEmpty ? agent.title : String(agent.summary.prefix(260))
        return """
        <button type="button" class="staff" data-agent="\(escape(agent.id))" aria-label="Chat with \(escape(agent.displayName))">
        <span class="heading"><h2>\(escape(agent.displayName))</h2><span class="model">\(escape(agent.modelName))</span></span>
        <span class="role">\(escape(agent.title))</span><span class="summary">\(escape(summary))</span>
        <span class="facts">Reports to \(escape(manager))<br>\(escape(scheduled.isEmpty ? "No fixed schedule" : scheduled))</span>
        <span class="chat">Chat with \(escape(agent.displayName)) →</span></button>
        """
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }
}
