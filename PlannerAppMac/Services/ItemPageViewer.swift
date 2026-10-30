import Foundation

/// Clicking an item in the Mac Planner list shows it in the panel's Browser tab: its own
/// page when it has one (a client overview report, a web page), otherwise the item itself
/// rendered as a tidy HTML page — title, details and notes with clickable links.
/// Editing is the pencil button on the row (or Edit… in its menu).
@MainActor
enum ItemPageViewer {
    /// Rendered item pages live beside `reports/` (not in it, so the reports list stays clean).
    static var pagesURL: URL { HermesBridge.workspaceURL.appendingPathComponent("item-pages", isDirectory: true) }

    static func open(_ item: PlannerItem) {
        if let url = pageURL(for: item) {
            show(url)
            return
        }
        try? FileManager.default.createDirectory(at: pagesURL, withIntermediateDirectories: true)
        let file = pagesURL.appendingPathComponent("item-\(item.id.uuidString.lowercased().prefix(8)).html")
        guard (try? Data(render(item).utf8).write(to: file)) != nil else { return }
        show(file)
    }

    /// The page an item points at, when it exists.
    static func pageURL(for item: PlannerItem) -> URL? {
        guard let link = item.pageTarget,
              let url = PageLink.url(for: link, workspace: HermesBridge.workspaceURL) else { return nil }
        return !url.isFileURL || FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Shows the panel with the Browser tab in front. Local pages may link to anything in
    /// the workspace (e.g. an item page to its report).
    static func show(_ url: URL) {
        UserDefaults.standard.set(true, forKey: "hermesPanelVisible")
        AgentPanelTabs.shared.currentBrowser.open(url, readAccess: url.isFileURL ? HermesBridge.workspaceURL : nil)
    }

    // MARK: - Rendering

    private static func render(_ item: PlannerItem) -> String {
        var chips: [String] = ["<span class=\"chip\">\(item.kind == .task ? "To-Do" : "Appointment")</span>"]
        if item.kind == .task {
            let p = item.priority
            chips.append("<span class=\"chip prio-\(p.title.lowercased())\">\(escape(p.title))</span>")
        }
        if item.isPinned { chips.append("<span class=\"chip\">📌 Pinned</span>") }
        if item.isDone { chips.append("<span class=\"chip done\">✓ Done</span>") }
        if item.isArchived { chips.append("<span class=\"chip\">Archived</span>") }

        var facts: [(String, String)] = []
        if let date = item.date {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            let dateOnly = parts.hour == 0 && parts.minute == 0
            var when = date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
            if !dateOnly { when += " · " + date.formatted(date: .omitted, time: .shortened) }
            if !dateOnly, let end = item.endDate { when += "–" + end.formatted(date: .omitted, time: .shortened) }
            facts.append((item.kind == .task ? "Due" : "When", escape(when)))
        }
        if let list = item.list?.name { facts.append(("List", escape(list))) }
        if !item.assignedTo.isEmpty { facts.append(("Assigned to", escape(item.assignedTo))) }
        facts.append(("Created", escape(item.createdAt.formatted(date: .abbreviated, time: .shortened))))

        var actions: [String] = []
        if let url = item.meetingURL {
            actions.append("<a class=\"button\" href=\"\(attr(url.absoluteString))\">🎥 Join meeting</a>")
        }

        let notes = PageLink.withoutLink(item.displayNotes)
        let notesHTML = notes.isEmpty ? "<p class=\"empty\">No notes.</p>" : renderNotes(notes)

        return """
        <!DOCTYPE html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(item.title))</title>
        <style>
        :root { color-scheme: light dark; --bg:#f6f7fb; --card:#fff; --ink:#1d1d1f; --muted:#6e6e73;
                --line:#e5e5ea; --accent:#5856d6; }
        @media (prefers-color-scheme: dark) { :root { --bg:#1c1c1e; --card:#2c2c2e; --ink:#f2f2f7;
                --muted:#a1a1a6; --line:#3a3a3c; --accent:#7d7aff; } }
        * { box-sizing: border-box; }
        body { margin:0; padding:28px 22px 40px; background:var(--bg); color:var(--ink);
               font: 15px/1.55 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif; }
        .card { max-width:760px; margin:0 auto; background:var(--card); border:1px solid var(--line);
                border-radius:16px; padding:26px 28px; box-shadow:0 1px 3px rgba(0,0,0,.05); }
        .chips { display:flex; flex-wrap:wrap; gap:6px; margin-bottom:10px; }
        .chip { font-size:12px; font-weight:600; padding:3px 10px; border-radius:999px;
                background:color-mix(in srgb, var(--accent) 12%, transparent); color:var(--accent); }
        .prio-critical { background:#ff3b301f; color:#ff3b30; } .prio-high { background:#ff95001f; color:#ff9500; }
        .prio-medium { background:#007aff1f; color:#007aff; } .prio-low { background:#34c7591f; color:#34c759; }
        .done { background:#34c7591f; color:#34c759; }
        h1 { font-size:24px; line-height:1.25; margin:0 0 18px; letter-spacing:-.01em; }
        dl { display:grid; grid-template-columns:max-content 1fr; gap:6px 18px; margin:0 0 20px;
             padding:14px 16px; border-radius:12px; background:var(--bg); }
        dt { color:var(--muted); font-size:13px; } dd { margin:0; font-size:14px; }
        h2 { font-size:13px; text-transform:uppercase; letter-spacing:.06em; color:var(--muted); margin:22px 0 8px; }
        p { margin:0 0 10px; } ul { margin:0 0 10px; padding-left:20px; } li { margin:2px 0; }
        .empty { color:var(--muted); font-style:italic; }
        a { color:var(--accent); text-decoration:none; word-break:break-word; } a:hover { text-decoration:underline; }
        .button { display:inline-block; padding:7px 14px; border-radius:10px; font-weight:600; font-size:14px;
                  background:var(--accent); color:#fff; margin:0 8px 16px 0; }
        .button:hover { text-decoration:none; opacity:.9; }
        .comment { border-left:3px solid var(--accent); padding:4px 0 4px 12px; margin:0 0 10px; }
        .comment .stamp { display:block; color:var(--muted); font-size:12px; }
        .foot { max-width:760px; margin:14px auto 0; color:var(--muted); font-size:12px; text-align:center; }
        </style></head>
        <body>
        <div class="card">
          <div class="chips">\(chips.joined())</div>
          <h1>\(escape(item.title))</h1>
          <dl>\(facts.map { "<dt>\($0.0)</dt><dd>\($0.1)</dd>" }.joined())</dl>
          \(actions.joined())
          <h2>Notes</h2>
          \(notesHTML)
        </div>
        <div class="foot">Edit with the ✎ button on the row in Planner.</div>
        </body></html>
        """
    }

    /// Notes as paragraphs, bullet lists and comment blocks, with links made clickable.
    private static func renderNotes(_ notes: String) -> String {
        var html: [String] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        func flush() {
            if !paragraph.isEmpty { html.append("<p>\(paragraph.joined(separator: "<br>"))</p>"); paragraph = [] }
            if !bullets.isEmpty { html.append("<ul>\(bullets.map { "<li>\($0)</li>" }.joined())</ul>"); bullets = [] }
        }
        for raw in notes.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if let comment = line.range(of: #"^Comment \(([^)]*)\):\s*"#, options: .regularExpression) {
                flush()
                let stamp = String(line[comment]).replacingOccurrences(of: #"^Comment \(|\):\s*$"#, with: "", options: .regularExpression)
                html.append("<div class=\"comment\"><span class=\"stamp\">\(escape(stamp))</span>\(linkify(String(line[comment.upperBound...])))</div>")
            } else if let bullet = line.range(of: #"^[-•*]\s+"#, options: .regularExpression) {
                if !paragraph.isEmpty { flush() }
                bullets.append(linkify(String(line[bullet.upperBound...])))
            } else {
                if !bullets.isEmpty { flush() }
                paragraph.append(linkify(line))
            }
        }
        flush()
        return html.joined(separator: "\n")
    }

    /// Escapes a line, then turns web addresses, e-mail addresses and workspace report paths
    /// into links.
    private static func linkify(_ text: String) -> String {
        let pattern = #"(https?://[^\s<>"]+[^\s<>".,;:!?)\]])|(reports/[^\s<>"()]+?\.html?)(?![\w/-])|([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return escape(text) }
        let ns = text as NSString
        var out = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += escape(ns.substring(with: NSRange(location: last, length: match.range.location - last)))
            let token = ns.substring(with: match.range)
            let href: String
            if match.range(at: 2).location != NSNotFound {
                href = HermesBridge.workspaceURL.appendingPathComponent(token).absoluteString
            } else if match.range(at: 3).location != NSNotFound {
                href = "mailto:" + token
            } else {
                href = token
            }
            out += "<a href=\"\(attr(href))\">\(escape(token))</a>"
            last = match.range.location + match.range.length
        }
        out += escape(ns.substring(from: last))
        return out
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func attr(_ s: String) -> String { escape(s).replacingOccurrences(of: "\"", with: "&quot;") }
}
