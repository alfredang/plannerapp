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
    /// Column headings for the principal's direct reports, so the chart reads like the Human
    /// Workforce chart (one column per department). Unknown leads fall back to their title.
    static let departments = ["atlas": "Operations", "oracle": "Strategy", "nova": "Growth"]

    /// Laid out like the Human Workforce org chart: the principal on top, one column per direct
    /// report (department header with headcount, the lead's card, then their team), compact cards
    /// that expand for details and the chat button, then a "who owns what" table.
    /// `zoomable` adds the full-screen button.
    static func render(chart: OrgNode, jobs: [ScheduledJob], dark: Bool, zoomable: Bool = true) -> String {
        let owns = AgentRoster.ownership
        let staffCount = chart.descendantIDs.intersection(AgentRoster.staffIDs).count
        let columns = chart.children.map { lead -> String in
            let team = staff(of: lead)
            let heading = departments[lead.agent?.id ?? ""] ?? (lead.agent?.title ?? lead.name)
            return "<div class=\"col\"><div class=\"ch\">\(escape(heading)) · \(escape(lead.name)) <span>\(team.count + 1)</span></div>"
                + card(lead, manager: chart.name, jobs: jobs, owns: owns, lead: true)
                + team.map { card($0, manager: lead.name, jobs: jobs, owns: owns, lead: false) }.joined()
                + "</div>"
        }.joined()
        let table = ownershipTable(chart: chart, jobs: jobs, owns: owns)
        let zoomButton = zoomable
            ? "<button type=\"button\" class=\"zoom\" id=\"zoom\" aria-label=\"Open the whole org chart in a large window\">⤢ Full screen</button>"
            : ""
        let palette = dark
            ? "--bg:#171b21;--card:#242a33;--ink:#eef1f5;--muted:#b9c4ce;--line:#44505c;--accent:#a8d9d7;--lead:#e2c99f"
            : "--bg:#f4f5f7;--card:#ffffff;--ink:#202833;--muted:#5c6974;--line:#d6dbe0;--accent:#376b69;--lead:#865e2f"
        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline';">
        <title>Agent Workforce Org Chart</title>
        <style>
        :root{color-scheme:\(dark ? "dark" : "light");\(palette)}
        *{box-sizing:border-box}body{margin:0;padding:22px;background:var(--bg);color:var(--ink);font:13.5px/1.45 -apple-system,BlinkMacSystemFont,sans-serif}
        h1{font:700 30px Georgia,serif;margin:0 0 6px}
        header{display:flex;justify-content:space-between;gap:16px;flex-wrap:wrap;align-items:flex-start}header p{color:var(--muted);margin:0 0 4px;max-width:860px}
        .zoom{font:600 13px -apple-system,sans-serif;padding:8px 14px;border-radius:8px;border:1px solid var(--accent);background:var(--card);color:var(--accent);cursor:pointer;white-space:nowrap}
        .tools{margin:12px 0 0;display:flex;gap:8px}.tools button{font:600 12px -apple-system,sans-serif;padding:5px 10px;border-radius:7px;border:1px solid var(--line);background:var(--card);color:var(--ink);cursor:pointer}
        .principal{max-width:340px;margin:16px auto 0;padding:12px;text-align:center;border:1px solid #c7ac82;background:rgba(199,172,130,.18);border-radius:10px}
        .principal h2{font:700 19px Georgia,serif;margin:0}.principal p{margin:2px 0 0;font-size:11.5px;color:var(--lead);text-transform:uppercase;letter-spacing:.06em}
        .stem{width:2px;height:18px;background:var(--line);margin:auto}
        .scroll{overflow-x:auto;padding-bottom:10px}.tree{display:flex;gap:14px;min-width:max-content;padding-top:18px;position:relative;justify-content:center;align-items:flex-start}
        .col{width:285px;position:relative;display:flex;flex-direction:column;gap:8px}
        .col::before{content:"";position:absolute;top:-18px;left:50%;height:18px;border-left:2px solid var(--line)}
        .col::after{content:"";position:absolute;top:-18px;left:-8px;right:-8px;border-top:2px solid var(--line)}
        .col:first-child::after{left:50%}.col:last-child::after{right:50%}.col:only-child::after{display:none}
        .ch{font-size:11.5px;font-weight:700;text-transform:uppercase;letter-spacing:.06em;color:var(--accent);background:var(--card);border:1px solid var(--line);border-top:3px solid var(--lead);border-radius:8px;padding:8px 10px;display:flex;justify-content:space-between}
        .ch span{color:var(--muted)}
        .person{background:var(--card);border:1px solid var(--line);border-left:4px solid var(--accent);border-radius:8px}
        .person.lead{border-left-color:var(--lead)}
        .person summary{cursor:pointer;padding:9px 10px;list-style:none;display:grid;grid-template-columns:1fr auto;gap:2px 8px}
        .person summary::-webkit-details-marker{display:none}.pn{font-weight:700}.pt{grid-column:1/3;color:var(--muted);font-size:12px}
        .tags{grid-column:1/3;display:flex;gap:5px;flex-wrap:wrap}
        .badge{font-size:10px;padding:2px 6px;border-radius:999px;background:rgba(55,107,105,.12);color:var(--accent);height:fit-content;white-space:nowrap}
        .badge.lead{background:rgba(199,172,130,.22);color:var(--lead)}.badge.model{font-family:ui-monospace,monospace}
        .pd{padding:0 10px 10px;border-top:1px dashed var(--line)}.kv{display:flex;justify-content:space-between;gap:8px;padding:3px 0;font-size:12.5px}
        .kv span{color:var(--muted);white-space:nowrap}.kv b{font-weight:600;text-align:right;word-break:break-word}
        .jdh{margin-top:8px;font-size:10.5px;text-transform:uppercase;letter-spacing:.06em;color:var(--muted)}
        .pd ul{margin:2px 0 4px;padding-left:16px}.pd p{margin:3px 0;font-size:12.5px}
        .chat{display:inline-block;margin-top:8px;font:600 12px -apple-system,sans-serif;color:var(--accent);background:none;border:0;padding:0;cursor:pointer}
        .chat:hover{text-decoration:underline}.chat:focus-visible,.person summary:focus-visible{outline:3px solid var(--accent);outline-offset:2px}
        .who{margin-top:28px}.who h2{font:700 19px Georgia,serif;margin:0 0 10px}
        .who table{width:100%;border-collapse:collapse;background:var(--card);border:1px solid var(--line);border-radius:8px;overflow:hidden;font-size:12px}
        .who th,.who td{text-align:left;vertical-align:top;padding:7px 9px;border-bottom:1px solid var(--line)}
        .who th{font-size:10px;text-transform:uppercase;letter-spacing:.07em;color:var(--muted)}.who td:first-child{font-weight:650;white-space:nowrap}
        .model{font:10px ui-monospace,monospace;color:var(--accent)}
        footer{margin-top:20px;font-size:12px;color:var(--muted)}
        </style></head><body>
        <header><div><h1>Agent Workforce Org Chart</h1>
        <p>\(staffCount) AI staff for \(escape(chart.name)): one owner per job, no overlaps. Nova finds and sizes growth; Oracle owns strategy and recommends; Alfred decides.</p>
        <p>Click an agent for what they own, their schedule and model, and the button to chat with them. Scroll sideways if the chart is wider than the pane.</p>
        <div class="tools"><button type="button" id="openall">Expand all</button><button type="button" id="closeall">Collapse all</button></div></div>\(zoomButton)</header>
        <div class="principal"><h2>\(escape(chart.name))</h2><p>\(escape(chart.title))</p></div>
        <div class="stem" aria-hidden="true"></div>
        <div class="scroll"><section class="tree" aria-label="Org chart">\(columns)</section></div>
        \(table)
        <footer>Ownership comes from the "who owns what" table in ~/DigitalWorkforce/COMPANY.md, reporting lines from its "reports to" lines, schedules from the scheduler (~/DigitalWorkforce/bin/scheduler.py) and models from each agent's definition. Each agent has its own saved chat.</footer>
        <script>
        document.querySelectorAll('[data-agent]').forEach(function(button){
          button.addEventListener('click',function(){window.webkit.messageHandlers.staffChat.postMessage({id:button.dataset.agent});});
        });
        document.getElementById('openall').onclick=function(){document.querySelectorAll('details').forEach(function(x){x.open=true})};
        document.getElementById('closeall').onclick=function(){document.querySelectorAll('details').forEach(function(x){x.open=false})};
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
        return when.isEmpty ? "On demand" : when.joined(separator: " · ")
    }

    /// One compact, expandable card, styled like a person on the Human Workforce chart.
    private static func card(_ node: OrgNode, manager: String, jobs: [ScheduledJob],
                             owns: [String: [AgentRoster.Ownership]], lead: Bool) -> String {
        guard let agent = node.agent else { return "" }
        let team = staff(of: node).compactMap { $0.agent?.displayName }
        let when = schedule(agent, jobs: jobs, owns: owns)
        // The tag shows the agent's main slot: its daily run when it has one (Nova's 06:43 scan, not Fri).
        let slots = when.components(separatedBy: " · ")
        let firstSlot = slots.first { $0.hasPrefix("Daily") } ?? slots.first ?? when
        var tags = "<span class=\"badge model\">\(escape(agent.modelName))</span><span class=\"badge\">🕒 \(escape(firstSlot))</span>"
        if lead && !team.isEmpty { tags += "<span class=\"badge lead\">Leads \(team.count)</span>" }
        let jobsOwned = owns[agent.id] ?? []
        let ownsBlock = jobsOwned.isEmpty
            ? (agent.summary.isEmpty ? "" : "<div class=\"jdh\">Role</div><p>\(escape(String(agent.summary.prefix(320))))</p>")
            : "<div class=\"jdh\">Owns</div><ul>" + jobsOwned.map { "<li>\(escape($0.job))</li>" }.joined() + "</ul>"
        let leadsRow = team.isEmpty ? "" : "<div class=\"kv\"><span>Leads</span><b>\(escape(team.joined(separator: ", ")))</b></div>"
        return """
        <details class="person\(lead ? " lead" : "")"><summary><span class="pn">\(escape(agent.displayName))</span><span></span>
        <span class="pt">\(escape(agent.title))</span><span class="tags">\(tags)</span></summary>
        <div class="pd">
        <div class="kv"><span>Reports to</span><b>\(escape(manager))</b></div>\(leadsRow)
        <div class="kv"><span>Schedule</span><b>\(escape(when))</b></div>
        <div class="kv"><span>Model</span><b>\(escape(agent.modelName))</b></div>
        \(ownsBlock)
        <button type="button" class="chat" data-agent="\(escape(agent.id))">Chat with \(escape(agent.displayName)) →</button>
        </div></details>
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
