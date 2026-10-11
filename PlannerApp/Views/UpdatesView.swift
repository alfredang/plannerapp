import SwiftUI
import SwiftData
import WebKit

/// The Digital Workforce's report pages, synced from the Mac through iCloud — newest day
/// first, past days collapsed — with the same per-card Reply as the Mac app.
struct UpdatesView: View {
    @Query(sort: [SortDescriptor(\AgentReport.dateKey, order: .reverse),
                  SortDescriptor(\AgentReport.modifiedAt, order: .reverse)])
    private var reports: [AgentReport]

    @State private var toggledDays: Set<String> = []
    @State private var search = ""

    private static let todayKey = Date().formatted(.iso8601.year().month().day())

    private var filtered: [AgentReport] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return reports }
        return reports.filter { ($0.title + " " + $0.agent + " " + $0.summary).lowercased().contains(q) }
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
        if !search.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        let openByDefault = key >= Self.todayKey
        return toggledDays.contains(key) ? !openByDefault : openByDefault
    }

    var body: some View {
        NavigationStack {
            List {
                if reports.isEmpty {
                    Text("No updates yet. Reports your agents publish on the Mac appear here once they sync through iCloud.")
                        .foregroundStyle(.secondary)
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
            .background(Theme.bg)
            .searchable(text: $search, prompt: "Search updates")
            .navigationTitle("Updates")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func row(_ report: AgentReport) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(report.title).font(.body.weight(.semibold)).foregroundStyle(.primary)
            if !report.summary.isEmpty {
                Text(report.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 8) {
                if !report.agent.isEmpty {
                    Text(report.agent).font(.caption.weight(.medium)).foregroundStyle(Theme.accent)
                }
                Text(report.modifiedAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
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
    @Query private var replies: [ReportReply]

    init(report: AgentReport) {
        self.report = report
        let file = report.file
        _replies = Query(filter: #Predicate<ReportReply> { $0.page == file })
    }

    var body: some View {
        ReportWebView(
            html: report.html, page: report.file,
            saved: replies.map { ["item": $0.item, "text": $0.text] },
            onReply: { item, text in
                context.insert(ReportReply(page: report.file, item: item, text: text, source: "iphone"))
                try? context.save()
            })
        .ignoresSafeArea(edges: .bottom)
        .navigationTitle(report.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ReportWebView: UIViewRepresentable {
    let html: String
    let page: String
    let saved: [[String: String]]
    let onReply: (String, String) -> Void

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
        web.loadHTMLString(html, baseURL: nil)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.show(in: web)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: ReportWebView?

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
