import SwiftUI
import AppKit

/// Sidebar ▸ Updates / Logs: the report pages the agents have published (the `reports/` folder and
/// its `index.json`, plus the Mac-only HR pages), newest first, grouped by day. Updates holds only the
/// briefs and weekly updates (`ReportPresentation.isUpdate`); Logs holds everything else, so checks,
/// scans and monitors don't bury the briefs. Clicking one opens it in the agent panel's Browser tab.
struct MacUpdatesPane: View {
    enum Feed { case updates, logs }
    var feed: Feed = .updates

    @ObservedObject private var browser = AgentBrowser.shared
    @AppStorage("hermesPanelVisible") private var panelVisible = true
    @State private var search = ""
    /// Past days start collapsed; the user's opens/closes are remembered for this session.
    @State private var toggledDays: Set<String> = []

    private func isExpanded(_ key: String) -> Bool {
        // A search shows every match; otherwise today is open and past days are closed.
        if !search.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        let openByDefault = key >= ReportPresentation.dayKey()
        return toggledDays.contains(key) ? !openByDefault : openByDefault
    }

    private var feedReports: [AgentBrowser.Report] {
        browser.reports.filter {
            ReportPresentation.isUpdate(file: $0.file, title: $0.displayTitle) == (feed == .updates)
        }
    }

    private var filtered: [AgentBrowser.Report] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return feedReports }
        return feedReports.filter {
            [$0.displayTitle, $0.agent ?? "", $0.summary ?? "", $0.date ?? ""]
                .joined(separator: " ").lowercased().contains(q)
        }
    }

    /// Days newest first; each day's Morning Brief precedes its other reports.
    private var groups: [(String, [AgentBrowser.Report])] {
        var byDay: [String: [AgentBrowser.Report]] = [:]
        for report in filtered { byDay[report.date ?? "Undated", default: []].append(report) }
        return byDay.keys.sorted(by: >).map { key in
            (key, (byDay[key] ?? []).sorted {
                let firstPinned = ReportPresentation.isPinnedMorningBrief(file: $0.file, title: $0.displayTitle)
                let secondPinned = ReportPresentation.isPinnedMorningBrief(file: $1.file, title: $1.displayTitle)
                if firstPinned != secondPinned { return firstPinned }
                if $0.modified != $1.modified { return ($0.modified ?? 0) > ($1.modified ?? 0) }
                return $0.file < $1.file
            })
        }
    }

    var body: some View {
        List {
            ForEach(groups, id: \.0) { day, reports in
                Section {
                    if isExpanded(day) {
                        ForEach(reports) { report in
                            row(report)
                        }
                    }
                } header: {
                    Button {
                        if toggledDays.contains(day) { toggledDays.remove(day) } else { toggledDays.insert(day) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: isExpanded(day) ? "chevron.down" : "chevron.right")
                                .font(.caption2.weight(.bold))
                                .frame(width: 10)
                            Text(Self.dayLabel(day))
                            Text("\(reports.count)").foregroundStyle(.tertiary)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if feedReports.isEmpty {
                ContentUnavailableView(
                    feed == .updates ? "No updates yet" : "No logs yet", systemImage: "doc.richtext",
                    description: Text(feed == .updates
                        ? "The briefs and weekly updates appear here: Morning Brief, Business Brief, and the weekly strategy, project, HR and AI news updates."
                        : "Everything else the agents publish: project checks, scans, watchers and monitors."))
            }
        }
        .searchable(text: $search, prompt: feed == .updates ? "Search updates" : "Search logs")
        .navigationTitle(feed == .updates ? "Updates" : "Logs")
        .navigationSubtitle("\(feedReports.count) report\(feedReports.count == 1 ? "" : "s")")
        .toolbar {
            ToolbarItem {
                Button { browser.reloadReports() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
            }
        }
        .onAppear { browser.reloadReports() }
    }

    private func row(_ report: AgentBrowser.Report) -> some View {
        let isOpen = browser.webView.url?.lastPathComponent == report.file
        return Button {
            panelVisible = true
            browser.open(report: report)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Text(Self.emoji(for: report.agent))
                    .font(.title3)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if ReportPresentation.isPinnedMorningBrief(file: report.file, title: report.displayTitle) {
                            Image(systemName: "pin.fill")
                                .font(.caption).foregroundStyle(Theme.accent)
                                .accessibilityLabel("Pinned Morning Brief")
                        }
                        Text(report.displayTitle)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                    }
                    if let summary = report.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    HStack(spacing: 8) {
                        if let agent = report.agent, !agent.isEmpty {
                            Text(agent).font(.caption.weight(.medium)).foregroundStyle(Theme.accent)
                        }
                        if let modified = report.modified {
                            Text(Date(timeIntervalSince1970: TimeInterval(modified))
                                .formatted(date: .omitted, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 6)
                if isOpen {
                    Image(systemName: "eye.fill").foregroundStyle(Theme.accent).help("Showing in the browser")
                } else {
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open in Browser Tab") { panelVisible = true; browser.open(report: report) }
            Button("Open in Safari") {
                NSWorkspace.shared.open(AgentBrowser.reportsURL.appendingPathComponent(report.file))
            }
            if let link = report.url, !link.isEmpty, let url = URL(string: link) {
                Button("Open Published Artifact") { panelVisible = true; browser.open(url) }
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([AgentBrowser.reportsURL.appendingPathComponent(report.file)])
            }
        }
    }

    private static func emoji(for agent: String?) -> String {
        switch agent?.lowercased() {
        case "atlas": return "📅"
        case "mercury": return "💼"
        case "muse": return "🎨"
        case "sage": return "📚"
        case "sentinel": return "🛡️"
        case "forge": return "🛠️"
        case "ledger": return "💰"
        case "oracle": return "🧭"
        case "nova": return "🚀"
        case "helm": return "🗂️"
        case "vesta": return "👥"
        default: return "📄"
        }
    }

    private static func dayLabel(_ iso: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let date = f.date(from: iso) else { return iso }
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}
