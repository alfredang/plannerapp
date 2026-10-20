import SwiftUI
import SwiftData
import WebKit

/// Standalone wrapper; Planner embeds the same content below its three top tabs.
struct UpdatesView: View {
    @State private var search = ""

    var body: some View {
        NavigationStack {
            UpdatesContentView(search: $search)
                .searchable(text: $search, prompt: "Search updates")
                .navigationTitle("Updates")
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct UpdatesContentView: View {
    private enum Scope: String, CaseIterable, Identifiable {
        case morning = "Morning Brief", other = "Other Updates"
        var id: String { rawValue }
    }

    @Query(sort: [SortDescriptor(\AgentReport.dateKey, order: .reverse),
                  SortDescriptor(\AgentReport.modifiedAt, order: .reverse)])
    private var reports: [AgentReport]

    @Environment(\.modelContext) private var context
    @Binding var search: String
    @State private var scope: Scope = .morning
    @State private var toggledDays: Set<String> = []

    private var filtered: [AgentReport] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return reports.filter { report in
            let matchesScope = scope == .morning ? report.isMorningBrief : !report.isMorningBrief
            let matchesSearch = q.isEmpty || (report.displayTitle + " " + report.agent + " " + report.summary)
                .lowercased().contains(q)
            return matchesScope && matchesSearch
        }
    }

    private var days: [(String, [AgentReport])] {
        var order: [String] = []
        var byDay: [String: [AgentReport]] = [:]
        for report in filtered {
            if byDay[report.dateKey] == nil { order.append(report.dateKey) }
            byDay[report.dateKey, default: []].append(report)
        }
        return order.map { ($0, byDay[$0] ?? []) }
    }

    private func isExpanded(_ key: String) -> Bool {
        if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        // Daily briefs stay visible throughout the history. Other reports open for today.
        let openByDefault = scope == .morning || key >= ReportPresentation.dayKey()
        return toggledDays.contains(key) ? !openByDefault : openByDefault
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Updates", selection: $scope) {
                ForEach(Scope.allCases) { item in Text(item.rawValue).tag(item) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("updates.scope")
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            List {
                if filtered.isEmpty {
                    ContentUnavailableView {
                        Label(scope == .morning ? "No morning brief yet" : "No other updates", systemImage: "doc.richtext")
                    } description: {
                        Text(search.isEmpty
                             ? "Reports published on your Mac appear here through iCloud."
                             : "No reports match your search.")
                    }
                    .listRowBackground(Color.clear)
                }
                ForEach(days, id: \.0) { key, items in
                    Section {
                        if isExpanded(key) {
                            ForEach(items) { report in
                                NavigationLink { ReportPageView(report: report) } label: { row(report) }
                            }
                        }
                    } header: {
                        Button {
                            if toggledDays.contains(key) { toggledDays.remove(key) } else { toggledDays.insert(key) }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: isExpanded(key) ? "chevron.down" : "chevron.right")
                                    .font(.caption2.weight(.bold))
                                Text(Self.label(key))
                                Text("\(items.count)").foregroundStyle(.tertiary)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            // Pull down to fetch new briefs and replies from iCloud.
            .refreshable { await CloudSyncStatus.shared.syncNow(context: context) }
        }
        .background(Theme.bg)
        .onChange(of: scope) { toggledDays = [] }
    }

    private func row(_ report: AgentReport) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(report.displayTitle).font(.body.weight(.semibold)).foregroundStyle(.primary)
            if !report.summary.isEmpty {
                Text(report.summary).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            }
            HStack(spacing: 8) {
                if !report.agent.isEmpty {
                    Text(report.agent).font(.caption.weight(.medium)).foregroundStyle(Theme.accent)
                }
                Text(report.modifiedAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private static func label(_ iso: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: iso) else { return iso }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

/// One report page. Replies typed under a card are saved as `ReportReply` (synced to the
/// Mac, which hands them to the agents).
struct ReportPageView: View {
    let report: AgentReport
    @Environment(\.modelContext) private var context
    @ObservedObject private var sync = CloudSyncStatus.shared
    @Query private var replies: [ReportReply]

    init(report: AgentReport) {
        self.report = report
        let file = report.file
        _replies = Query(filter: #Predicate<ReportReply> { $0.page == file })
    }

    var body: some View {
        ReportWebView(
            html: report.displayHTML, page: report.file,
            saved: replies.map { ["item": $0.item, "text": $0.text] },
            onReply: { item, text in
                context.insert(ReportReply(page: report.file, item: item, text: text, source: "iphone"))
                try? context.save()
            },
            onRefresh: { await sync.syncNow(context: context) })
        .ignoresSafeArea(edges: .bottom)
        .navigationTitle(report.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await sync.syncNow(context: context) }
                } label: {
                    if sync.isSyncing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(sync.isSyncing)
                .accessibilityLabel("Sync with iCloud")
                .accessibilityIdentifier("report.sync")
            }
        }
    }
}

private struct ReportWebView: UIViewRepresentable {
    let html: String
    let page: String
    let saved: [[String: String]]
    let onReply: (String, String) -> Void
    let onRefresh: () async -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = config.userContentController
        let pageName = (try? String(data: JSONSerialization.data(withJSONObject: [page], options: .fragmentsAllowed), encoding: .utf8)) ?? "[\"\"]"
        controller.addUserScript(WKUserScript(source: "window.__plPage = \(pageName)[0];",
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: ReportReplyScript.source,
                                              injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        controller.add(context.coordinator, name: "reply")
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        context.coordinator.parent = self
        // Pull down to fetch the latest brief and replies from iCloud.
        let refresh = UIRefreshControl()
        refresh.addTarget(context.coordinator, action: #selector(Coordinator.pulled(_:)), for: .valueChanged)
        web.scrollView.refreshControl = refresh
        context.coordinator.loadedHTML = html
        web.loadHTMLString(html, baseURL: nil)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.parent = self
        // The Mac re-publishes a brief under the same file; reload when its HTML changes.
        if context.coordinator.loadedHTML != html {
            context.coordinator.loadedHTML = html
            web.loadHTMLString(html, baseURL: nil)
        } else {
            context.coordinator.show(in: web)
        }
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: ReportWebView?
        var loadedHTML = ""

        @MainActor @objc func pulled(_ control: UIRefreshControl) {
            Task { @MainActor in
                await parent?.onRefresh()
                control.endRefreshing()
            }
        }

        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            guard let body = m.body as? [String: String], let item = body["item"],
                  let text = body["text"]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
            parent?.onReply(item, text)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { show(in: webView) }

        func show(in web: WKWebView) {
            guard let saved = parent?.saved,
                  let data = try? JSONSerialization.data(withJSONObject: saved),
                  let json = String(data: data, encoding: .utf8) else { return }
            web.evaluateJavaScript("if (window.__plShow) window.__plShow(\(json));")
        }
    }
}
