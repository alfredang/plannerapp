import SwiftUI
import WebKit

/// Sidebar ▸ Goals and Ideas: they are documents, not rows to tick off. The selected goal or idea
/// fills the pane as its rendered page, with a tab for each one. While a page doesn't exist yet,
/// the same space says where its research has got to.
struct MacResearchPagesView: View {
    /// In tab order: never empty when shown (the pane has its own empty state).
    let items: [PlannerItem]
    let onEdit: (PlannerItem) -> Void
    let onDelete: (PlannerItem) -> Void

    @State private var selectedID: UUID?
    @StateObject private var browser = AgentBrowser.makeEmbedded()

    private var researcher: ItemResearcher { .shared }

    private var selected: PlannerItem? {
        items.first { $0.id == selectedID } ?? items.first
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            if let item = selected {
                page(for: item)
            }
        }
        // Something just said or typed opens straight away.
        .onChange(of: items.map(\.id)) { old, new in
            if let added = new.first(where: { !old.contains($0) }), !old.isEmpty { selectedID = added }
        }
    }

    // MARK: - Tabs

    private var tabBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(items) { tab($0) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
            if let item = selected {
                actions(for: item)
                    .padding(.trailing, 12)
            }
        }
        .background(.bar)
    }

    private func tab(_ item: PlannerItem) -> some View {
        let isSelected = item.id == selected?.id
        return Button {
            selectedID = item.id
        } label: {
            HStack(spacing: 5) {
                tabMark(item)
                Text(item.title).lineLimit(1)
            }
            .font(.callout.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: 260)
            .background(isSelected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.quaternary), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(item.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func tabMark(_ item: PlannerItem) -> some View {
        switch researcher.status(of: item) {
        case .researching:
            ProgressView().controlSize(.mini)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .queued, .unavailable:
            Image(systemName: "clock")
        case nil:
            if item.isDone { Image(systemName: "checkmark.circle.fill") }
        }
    }

    private func actions(for item: PlannerItem) -> some View {
        Menu {
            if !item.isDone {
                Button("Research Again") { researcher.researchAgain(item) }
                    .disabled(researcher.status(of: item) == .researching)
            }
            if ItemPageViewer.pageURL(for: item) != nil {
                Button("Open in Browser Tab") { ItemPageViewer.open(item) }
            }
            Button("Edit…") { onEdit(item) }
            if item.isGoal {
                Button(item.isDone ? "Mark Not Achieved" : "Mark Achieved") {
                    withAnimation { item.toggleDone() }
                }
            }
            Divider()
            Button("Delete…", role: .destructive) { onDelete(item) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Research again, edit or delete this \(item.kind.title.lowercased())")
        .accessibilityLabel("Page actions")
    }

    // MARK: - The page

    @ViewBuilder
    private func page(for item: PlannerItem) -> some View {
        let status = researcher.status(of: item)
        if let url = ItemPageViewer.pageURL(for: item) {
            VStack(spacing: 0) {
                if status == .researching || status == .queued {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("\(ItemResearcher.agentName) is redoing this page. The new one appears here when it's ready.")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    Divider()
                }
                ResearchPageWebView(browser: browser, url: url)
            }
        } else {
            pendingPage(for: item, status: status)
        }
    }

    private func pendingPage(for item: PlannerItem, status: ItemResearcher.Status?) -> some View {
        let agent = ItemResearcher.agentName
        return ContentUnavailableView {
            switch status {
            case .failed:
                Label("Research failed", systemImage: "exclamationmark.triangle")
            case .unavailable:
                Label("Research unavailable", systemImage: item.kind.symbol)
            case .queued:
                Label("Waiting for research", systemImage: "clock")
            case .researching:
                Label {
                    Text("\(agent) is researching this")
                } icon: {
                    ProgressView()
                }
            case nil:
                Label("No page", systemImage: item.kind.symbol)
            }
        } description: {
            switch status {
            case .failed:
                Text("“\(item.title)” has no page yet. The log is in ~/DigitalWorkforce/logs.")
            case .unavailable:
                Text("Research needs the Digital Workforce agents on this Mac.")
            case .queued:
                Text("“\(item.title)” starts when a research slot is free.")
            case .researching:
                Text("“\(item.title)” gets its page here in about 10 minutes: review, market research, competitor analysis, features, recommendations, strategy and steps to implement.")
            case nil:
                Text("“\(item.title)” has no page on this Mac.")
            }
        } actions: {
            if status == .failed || (status == nil && !item.isDone) {
                Button("Research Again") { researcher.researchAgain(item) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shows a local report page (or web page) in the pane, and picks up a rewritten file: Research
/// Again on the same day writes the same file name.
private struct ResearchPageWebView: NSViewRepresentable {
    let browser: AgentBrowser
    let url: URL

    final class Coordinator {
        var loaded: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView { browser.webView }

    func updateNSView(_ view: WKWebView, context: Context) {
        let modified = url.isFileURL
            ? (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            : nil
        let key = url.absoluteString + (modified.map { " \($0.timeIntervalSince1970)" } ?? "")
        guard context.coordinator.loaded != key else { return }
        context.coordinator.loaded = key
        // Links stay under the workspace, like the Browser tab's item pages.
        browser.open(url, readAccess: url.isFileURL ? HermesBridge.workspaceURL : nil)
    }
}
