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
        let view = Self.makeWebView(handler: context.coordinator)
        updateNSView(view, context: context)
        return view
    }

    static func makeWebView(handler: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(handler, name: "staffChat")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = handler
        view.setValue(false, forKey: "drawsBackground")
        view.setAccessibilityIdentifier("workforce.orgChart")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onOpenAgent = onOpenAgent
        coordinator.allowedIDs = chart.descendantIDs.intersection(AgentRoster.staffIDs)
        let dark = colorScheme == .dark
        coordinator.fullHTML = WorkforceArtifactHTML.render(chart: chart, jobs: jobs, dark: dark, zoomable: false)
        let html = WorkforceArtifactHTML.render(chart: chart, jobs: jobs, dark: dark, zoomable: true)
        guard coordinator.html != html else { return }
        coordinator.html = html
        view.loadHTMLString(html, baseURL: nil)
        coordinator.refreshZoomWindow()
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "staffChat")
        view.navigationDelegate = nil
        coordinator.closeZoomWindow()
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate {
        var onOpenAgent: (String) -> Void
        var allowedIDs: Set<String> = []
        var html = ""
        /// The same chart without the zoom button, for the full-screen window.
        var fullHTML = ""
        private var zoomWindow: NSWindow?
        private var zoomView: WKWebView?
        init(onOpenAgent: @escaping (String) -> Void) { self.onOpenAgent = onOpenAgent }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: String] else { return }
            if body["zoom"] != nil {
                openZoomWindow()
                return
            }
            guard let id = body["id"], allowedIDs.contains(id) else { return }
            if message.webView === zoomView { closeZoomWindow() }
            onOpenAgent(id)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // This artifact has no remote content or navigable links.
            decisionHandler(action.request.url?.scheme == "about" ? .allow : .cancel)
        }

        /// The whole chart in its own large window (90% of the screen), so every branch fits.
        private func openZoomWindow() {
            if let zoomWindow {
                zoomWindow.makeKeyAndOrderFront(nil)
                return
            }
            let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let size = NSSize(width: frame.width * 0.92, height: frame.height * 0.92)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "Digital Workforce Org Chart"
            window.isReleasedWhenClosed = false
            window.delegate = self
            let view = DigitalWorkforceArtifactView.makeWebView(handler: self)
            view.setAccessibilityIdentifier("workforce.orgChart.full")
            window.contentView = view
            view.loadHTMLString(fullHTML, baseURL: nil)
            window.center()
            window.makeKeyAndOrderFront(nil)
            zoomWindow = window
            zoomView = view
        }

        func refreshZoomWindow() {
            zoomView?.loadHTMLString(fullHTML, baseURL: nil)
        }

        func closeZoomWindow() {
            zoomWindow?.close()
        }

        func windowWillClose(_ notification: Notification) {
            zoomView?.configuration.userContentController.removeScriptMessageHandler(forName: "staffChat")
            zoomView?.navigationDelegate = nil
            zoomView = nil
            zoomWindow = nil
        }
    }
}

enum WorkforceArtifactHTML {
    /// A horizontal org chart: the principal on top, one column per direct report with that
    /// lead's team beneath it, then a "who owns what" table. `zoomable` adds the full-screen button.
    static func render(chart: OrgNode, jobs: [ScheduledJob], dark: Bool, zoomable: Bool = true) -> String {
        let owns = AgentRoster.ownership
        let staffCount = chart.descendantIDs.intersection(AgentRoster.staffIDs).count
        let branches = chart.children.map { lead -> String in
            let team = staff(of: lead)
            let sub = team.isEmpty ? "" : "<div class=\"sub\" aria-label=\"Reports to \(escape(lead.name))\">"
                + team.map { card($0, manager: lead.name, jobs: jobs, owns: owns, lead: false) }.joined() + "</div>"
            return "<div class=\"branch\">" + card(lead, manager: chart.name, jobs: jobs, owns: owns, lead: true) + sub + "</div>"
        }.joined()
        let table = ownershipTable(chart: chart, jobs: jobs, owns: owns)
        let background = dark ? "#171b21" : "#f4f5f7"
        let surface = dark ? "#242a33" : "#ffffff"
        let foreground = dark ? "#eef1f5" : "#202833"
        let secondary = dark ? "#b9c4ce" : "#5c6974"
        let border = dark ? "#44505c" : "#c9d0d6"
        let zoomButton = zoomable
            ? "<button type=\"button\" class=\"zoom\" id=\"zoom\" aria-label=\"Open the whole org chart in a large window\">⤢ Full screen</button>"
            : ""
        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline';">
        <title>Digital Workforce Org Chart</title>
        <style>
        :root{color-scheme:\(dark ? "dark" : "light");--bg:\(background);--surface:\(surface);--text:\(foreground);--muted:\(secondary);--border:\(border);--accent:\(dark ? "#a8d9d7" : "#376b69");--lead:\(dark ? "#e2c99f" : "#865e2f")}
        *{box-sizing:border-box}body{margin:0;padding:22px;background:var(--bg);color:var(--text);font:14px/1.45 -apple-system,BlinkMacSystemFont,sans-serif}
        main{max-width:1500px;margin:auto}
        header{display:flex;justify-content:space-between;align-items:flex-start;gap:16px;flex-wrap:wrap}
        h1{font:700 clamp(24px,3vw,34px)/1.15 Georgia,serif;margin:0 0 8px}header p{color:var(--muted);margin:0 0 6px;max-width:820px}.hint{font-size:13px}
        .zoom{font:600 13px -apple-system,sans-serif;padding:8px 14px;border-radius:8px;border:1px solid var(--accent);background:var(--surface);color:var(--accent);cursor:pointer;white-space:nowrap}
        .zoom:hover{background:var(--accent);color:var(--surface)}
        .principal{max-width:360px;margin:18px auto 0;padding:14px;text-align:center;border:1px solid \(dark ? "#9b835a" : "#c7ac82");background:\(dark ? "#3c3225" : "#f4e8d2");border-radius:10px}
        .principal h2{font:700 21px Georgia,serif;margin:0 0 3px}.principal p{margin:0;font-size:12px;color:var(--lead);text-transform:uppercase;letter-spacing:.06em}
        .stem{height:22px;width:2px;background:var(--border);margin:auto}
        .scroll{overflow-x:auto;padding-bottom:8px}
        .tree{display:flex;gap:18px;align-items:flex-start;min-width:max-content;margin:0 auto;padding-top:22px;position:relative;justify-content:center}
        .branch{position:relative;width:300px;display:flex;flex-direction:column;gap:10px}
        .branch::before{content:"";position:absolute;top:-22px;left:50%;height:22px;border-left:2px solid var(--border)}
        .branch::after{content:"";position:absolute;top:-22px;left:-9px;right:-9px;border-top:2px solid var(--border)}
        .branch:first-child::after{left:50%}.branch:last-child::after{right:50%}.branch:only-child::after{display:none}
        .sub{display:flex;flex-direction:column;gap:9px;margin-left:18px;padding-left:16px;border-left:2px solid var(--border)}
        .sub .staff{position:relative}.sub .staff::before{content:"";position:absolute;left:-18px;top:26px;width:16px;border-top:2px solid var(--border)}
        .staff{display:flex;flex-direction:column;align-items:stretch;gap:6px;text-align:left;width:100%;padding:12px 13px;background:var(--surface);color:var(--text);border:1px solid var(--border);border-top:3px solid var(--accent);border-radius:9px;cursor:pointer;font:inherit;transition:transform .12s,border-color .12s}
        .staff.lead{border-top:4px solid var(--lead);box-shadow:0 1px 3px rgba(0,0,0,.08)}
        .staff:hover{transform:translateY(-2px);border-color:var(--accent)}.staff:focus-visible{outline:3px solid var(--accent);outline-offset:3px}
        .staff h2{font:700 18px Georgia,serif;margin:0}.heading{display:flex;align-items:center;justify-content:space-between;gap:8px}
        .model{font:10px ui-monospace,monospace;color:var(--accent);padding:3px 6px;border-radius:4px;background:\(dark ? "#203d3c" : "#e4f0ee");white-space:nowrap}
        .role{font-size:10.5px;text-transform:uppercase;letter-spacing:.06em;color:var(--accent);font-weight:650}
        .summary{font-size:12px;display:-webkit-box;-webkit-line-clamp:3;-webkit-box-orient:vertical;overflow:hidden}
        .owns{font-size:12px}.owns b{display:block;font-size:9.5px;text-transform:uppercase;letter-spacing:.08em;color:var(--muted);margin-bottom:2px}.owns ul{margin:0;padding-left:15px;display:grid;gap:2px}
        .facts{color:var(--muted);font:10.5px/1.55 ui-monospace,monospace;border-top:1px dashed var(--border);padding-top:5px}
        .chat{color:var(--accent);font-size:11.5px;font-weight:600}
        .who{margin-top:30px}.who h2{font:700 20px Georgia,serif;margin:0 0 10px}
        .who table{width:100%;border-collapse:collapse;background:var(--surface);border:1px solid var(--border);border-radius:8px;overflow:hidden;font-size:12px}
        .who th,.who td{text-align:left;vertical-align:top;padding:7px 9px;border-bottom:1px solid var(--border)}
        .who th{font-size:10px;text-transform:uppercase;letter-spacing:.07em;color:var(--muted)}.who td:first-child{font-weight:650;white-space:nowrap}
        .footer{padding-top:18px;color:var(--muted);font-size:12px}
        @media(prefers-reduced-motion:reduce){.staff{transition:none}.staff:hover{transform:none}}
        </style></head><body><main>
        <header><div><h1>Digital Workforce Org Chart</h1>
        <p>\(staffCount) AI staff running a one-person company for \(escape(chart.name)): one owner per job, no overlaps. Planner is the master schedule; agents propose, Alfred decides.</p>
        <p class="hint">Select a staff card to chat with that agent. Scroll sideways if the chart is wider than the pane.</p></div>\(zoomButton)</header>
        <section class="principal" aria-label="Principal"><h2>\(escape(chart.name))</h2><p>\(escape(chart.title))</p></section>
        <div class="stem" aria-hidden="true"></div>
        <div class="scroll"><section class="tree" aria-label="Org chart">\(branches)</section></div>
        \(table)
        <footer class="footer">Ownership comes from the "who owns what" table in ~/DigitalWorkforce/COMPANY.md, reporting lines from its "reports to" lines, schedules from the scheduler (~/DigitalWorkforce/bin/scheduler.py) and models from each agent's definition. Each staff member has a separate saved chat.</footer>
        </main><script>
        document.querySelectorAll('[data-agent]').forEach(function(button){
          button.addEventListener('click',function(){window.webkit.messageHandlers.staffChat.postMessage({id:button.dataset.agent});});
        });
        var zoom=document.getElementById('zoom');
        if(zoom){zoom.addEventListener('click',function(){window.webkit.messageHandlers.staffChat.postMessage({zoom:'1'});});}
        </script></body></html>
        """
    }

    /// Staff (not helper agents) who report to `lead`.
    private static func staff(of lead: OrgNode) -> [OrgNode] {
        lead.children.filter { AgentRoster.staffIDs.contains($0.id) }
    }

    /// The agent's schedule: its scheduler jobs, else the timing in the ownership table.
    private static func schedule(_ agent: AgentProfile, jobs: [ScheduledJob], owns: [String: [AgentRoster.Ownership]]) -> String {
        let scheduled = jobs.filter { $0.detail?.lowercased() == agent.id }.map(\.schedule)
        if !scheduled.isEmpty { return scheduled.joined(separator: " · ") }
        let when = (owns[agent.id] ?? []).map(\.when).filter { !$0.isEmpty }
        return when.isEmpty ? "No fixed schedule" : when.joined(separator: " · ")
    }

    private static func card(_ node: OrgNode, manager: String, jobs: [ScheduledJob],
                             owns: [String: [AgentRoster.Ownership]], lead: Bool) -> String {
        guard let agent = node.agent else { return "" }
        let summary = agent.summary.isEmpty ? agent.title : String(agent.summary.prefix(260))
        let jobsOwned = owns[agent.id] ?? []
        let body = jobsOwned.isEmpty
            ? "<span class=\"summary\">\(escape(summary))</span>"
            : "<span class=\"owns\"><b>Owns</b><ul>" + jobsOwned.map { "<li>\(escape($0.job))</li>" }.joined() + "</ul></span>"
        let team = staff(of: node).compactMap { $0.agent?.displayName }
        let leadsLine = team.isEmpty ? "" : "<br>Leads \(escape(team.joined(separator: ", ")))"
        return """
        <button type="button" class="staff\(lead ? " lead" : "")" data-agent="\(escape(agent.id))" aria-label="Chat with \(escape(agent.displayName))">
        <span class="heading"><h2>\(escape(agent.displayName))</h2><span class="model">\(escape(agent.modelName))</span></span>
        <span class="role">\(escape(agent.title))</span>\(body)
        <span class="facts">Reports to \(escape(manager))\(leadsLine)<br>🕒 \(escape(schedule(agent, jobs: jobs, owns: owns)))</span>
        <span class="chat">Chat with \(escape(agent.displayName)) →</span></button>
        """
    }

    /// "Who owns what": one row per staff member, in chart order.
    private static func ownershipTable(chart: OrgNode, jobs: [ScheduledJob],
                                       owns: [String: [AgentRoster.Ownership]]) -> String {
        var rows: [String] = []
        var seen = Set<String>()
        func walk(_ node: OrgNode, manager: String) {
            for child in staff(of: node) {
                if let agent = child.agent, seen.insert(agent.id).inserted {
                    let jobsOwned = (owns[agent.id] ?? []).map(\.job)
                    let what = jobsOwned.isEmpty ? agent.title : jobsOwned.joined(separator: "; ")
                    rows.append("<tr><td>\(escape(agent.displayName))</td><td>\(escape(agent.title))</td><td>\(escape(what))</td>"
                                + "<td><span class=\"model\">\(escape(agent.modelName))</span></td><td>\(escape(manager))</td>"
                                + "<td>\(escape(schedule(agent, jobs: jobs, owns: owns)))</td></tr>")
                }
                walk(child, manager: child.name)
            }
        }
        walk(chart, manager: chart.name)
        guard !rows.isEmpty else { return "" }
        return """
        <section class="who" aria-label="Who owns what"><h2>Who owns what</h2><table>
        <thead><tr><th>Agent</th><th>Role</th><th>Owns (one owner per job)</th><th>Model</th><th>Reports to</th><th>Schedule</th></tr></thead>
        <tbody>\(rows.joined())</tbody></table></section>
        """
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }
}
