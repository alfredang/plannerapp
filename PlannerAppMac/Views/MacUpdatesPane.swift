import SwiftUI
import AppKit

/// Sidebar ▸ Updates: the history of every report page the agents have published (the
/// `reports/` folder and its `index.json`), newest first, grouped by day. Clicking one opens it
/// in the agent panel's Browser tab.
struct MacUpdatesPane: View {
    @ObservedObject private var browser = AgentBrowser.shared
    @AppStorage("hermesPanelVisible") private var panelVisible = true
    @State private var search = ""
    /// Past days start collapsed; the user's opens/closes are remembered for this session.
    @State private var toggledDays: Set<String> = []

    private static let todayKey: String = Date().formatted(.iso8601.year().month().day())

    private func isExpanded(_ key: String) -> Bool {
        // A search shows every match; otherwise today is open and past days are closed.
        if !search.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        let openByDefault = key >= Self.todayKey
        return toggledDays.contains(key) ? !openByDefault : openByDefault
    }

    private var filtered: [AgentBrowser.Report] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return browser.reports }
        return browser.reports.filter {
            [$0.displayTitle, $0.agent ?? "", $0.summary ?? "", $0.date ?? ""]
                .joined(separator: " ").lowercased().contains(q)
        }
    }

    /// (day key, reports) — days newest first, and newest first within each day.
    private var groups: [(String, [AgentBrowser.Report])] {
        var byDay: [String: [AgentBrowser.Report]] = [:]
        for report in filtered { byDay[report.date ?? "Undated", default: []].append(report) }
        return byDay.keys.sorted(by: >).map { key in
            (key, (byDay[key] ?? []).sorted { ($0.modified ?? 0) > ($1.modified ?? 0) })
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
            if browser.reports.isEmpty {
                ContentUnavailableView(
                    "No updates yet", systemImage: "doc.richtext",
                    description: Text("Reports your agents publish appear here — the 07:30 Morning Updates brief, daily briefs and weekly reviews."))
            }
        }
        .searchable(text: $search, prompt: "Search updates")
        .navigationTitle("Updates")
        .navigationSubtitle("\(browser.reports.count) report\(browser.reports.count == 1 ? "" : "s")")
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
                    Text(report.displayTitle)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
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
