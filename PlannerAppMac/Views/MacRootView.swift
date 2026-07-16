import SwiftUI
import SwiftData
import AppKit

/// A fixed sidebar destination. The smart categories filter the planner pane; Calendar,
/// Archive, Feedback and About swap in their own panes. User-created lists are handled
/// separately via `SidebarSelection.userList`.
enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    // Smart lists
    case all, today, scheduled, todos, appointments
    // Browse
    case calendar, archive
    // Support
    case feedback, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:          return "All Items"
        case .today:        return "Today"
        case .scheduled:    return "Scheduled"
        case .todos:        return "To-Dos"
        case .appointments: return "Appointments"
        case .calendar:     return "Calendar"
        case .archive:      return "Archive"
        case .feedback:     return "Feedback"
        case .about:        return "About"
        }
    }

    var symbol: String {
        switch self {
        case .all:          return "tray.full.fill"
        case .today:        return "star.fill"
        case .scheduled:    return "clock.fill"
        case .todos:        return "checklist"
        case .appointments: return "calendar"
        case .calendar:     return "calendar.badge.clock"
        case .archive:      return "archivebox.fill"
        case .feedback:     return "bubble.left.and.bubble.right.fill"
        case .about:        return "info.circle.fill"
        }
    }

    static let smartLists: [SidebarItem] = [.all, .today, .scheduled, .todos, .appointments]
    static let support: [SidebarItem] = [.feedback, .about]

    /// Whether an active (non-archived) item belongs to this smart category.
    func contains(_ item: PlannerItem) -> Bool {
        switch self {
        case .all:
            return true
        case .today:
            guard let date = item.date else { return false }
            return Calendar.current.isDateInToday(date)
        case .scheduled:
            return item.date != nil
        case .todos:
            return item.kind == .task
        case .appointments:
            return item.kind == .appointment
        default:
            return false
        }
    }
}

/// What is selected in the sidebar: a fixed category or one of the user's own lists.
enum SidebarSelection: Hashable {
    case category(SidebarItem)
    case userList(UUID)
}

/// Desktop root: two-column layout. Left — smart categories plus the user's own lists
/// (create / rename / delete). Right — the planner pane (item list + chatbot-style capture
/// bar) or a dedicated pane.
struct MacRootView: View {
    @Environment(\.modelContext) private var context

    @State private var selection: SidebarSelection = .category(.all)
    @State private var showingNewList = false
    @State private var newListName = ""
    @State private var renamingList: PlannerList?
    @State private var renameText = ""

    /// Whether the Hermes agent terminal panel is shown. Shared with the View-menu command
    /// in `PlannerMacApp` through UserDefaults; defaults to visible so the agent auto-starts.
    @AppStorage("hermesPanelVisible") private var hermesVisible = true

    // Active items, for the sidebar badge counts.
    @Query(filter: #Predicate<PlannerItem> { !$0.isArchived })
    private var activeItems: [PlannerItem]

    @Query(filter: #Predicate<PlannerItem> { $0.isArchived })
    private var archivedItems: [PlannerItem]

    @Query(sort: \PlannerList.createdAt)
    private var lists: [PlannerList]

    /// User-adjustable width of the Hermes panel (drag its left edge). Persisted.
    @AppStorage("hermesPanelWidth") private var hermesPanelWidth = 400.0
    @State private var panelDragStartWidth: CGFloat?
    @State private var dividerHovered = false

    @ObservedObject private var syncStatus = CloudSyncStatus.shared

    private static let panelMinWidth: CGFloat = 280
    /// Below this detail-area width the panel overlays the content (sliding sheet style)
    /// instead of sitting beside it — keeps small windows usable.
    private static let compactThreshold: CGFloat = 680

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailWithTerminal
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        Button {
                            withAnimation { hermesVisible.toggle() }
                        } label: {
                            Image(systemName: "terminal")
                        }
                        .help(hermesVisible ? "Hide the Hermes agent panel (⌥⌘T)" : "Show the Hermes agent panel (⌥⌘T)")
                        .accessibilityLabel("Toggle Hermes agent panel")
                    }
                }
        }
        .onChange(of: lists.count) {
            // If the selected user list was deleted (locally or via sync), fall back to All.
            if case .userList(let id) = selection, !lists.contains(where: { $0.id == id }) {
                selection = .category(.all)
            }
        }
        // Hermes agent bridge: keep the workspace + JSON snapshot current, and execute the
        // planner:// commands the agent issues from the terminal panel (see HermesBridge).
        .task {
            HermesBridge.prepareWorkspace()
            HermesBridge.writeSnapshot(context: context)
        }
        .onChange(of: dataFingerprint) {
            HermesBridge.writeSnapshot(context: context)
        }
        .onOpenURL { url in
            guard url.scheme == "planner" else { return }
            HermesBridge.handle(url, context: context)
        }
    }

    // MARK: - Detail + Hermes terminal layout

    /// The detail pane with the Hermes terminal beside it. Adaptive: on a roomy window the
    /// panel docks to the right with a draggable divider; on a narrow window it slides OVER
    /// the content (sheet style, tap the scrim to dismiss) so nothing gets squeezed or
    /// clipped. All widths are clamped to the available space.
    private var detailWithTerminal: some View {
        GeometryReader { geo in
            let compact = geo.size.width < Self.compactThreshold
            // One width for BOTH modes, rounded to whole pixels: a terminal reflows (and
            // garbles already-drawn TUI borders) on every width change, so docked ↔ overlay
            // switches must not resize it.
            let panelWidth = min(max(Self.panelMinWidth, CGFloat(hermesPanelWidth)),
                                 max(Self.panelMinWidth, geo.size.width * 0.55)).rounded()

            HStack(spacing: 0) {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if hermesVisible && !compact {
                    resizeDivider(maxPanelWidth: geo.size.width * 0.55)
                    MacTerminalPanel(isVisible: $hermesVisible)
                        .frame(width: panelWidth)
                        .transition(.move(edge: .trailing))
                }
            }
            .overlay {
                if hermesVisible && compact {
                    ZStack(alignment: .trailing) {
                        Color.black.opacity(0.3)
                            .onTapGesture { withAnimation { hermesVisible = false } }
                            .transition(.opacity)
                        HStack(spacing: 0) {
                            resizeDivider(maxPanelWidth: geo.size.width - 44)
                            MacTerminalPanel(isVisible: $hermesVisible)
                                .frame(width: min(panelWidth, (geo.size.width - 44).rounded()))
                        }
                        .shadow(color: .black.opacity(0.35), radius: 14, x: -6, y: 0)
                        .transition(.move(edge: .trailing))
                    }
                }
            }
            .animation(.easeInOut(duration: 0.22), value: hermesVisible)
        }
    }

    /// Visible column divider between the item list and the Hermes panel — drag to resize
    /// the columns (the width persists), highlights on hover with a grab handle. Mouse
    /// handling is AppKit-based (`PanelResizeHandle`): a SwiftUI DragGesture here loses
    /// events to the neighbouring AppKit terminal view.
    private func resizeDivider(maxPanelWidth: CGFloat) -> some View {
        let active = dividerHovered || panelDragStartWidth != nil
        return ZStack {
            Rectangle()
                .fill(Color.primary.opacity(active ? 0.08 : 0))
            // VSCode-style: the hairline becomes a solid blue bar on hover / while dragging.
            Rectangle()
                .fill(active ? Color(nsColor: .controlAccentColor) : Color(nsColor: .separatorColor))
                .frame(width: active ? 3 : 1)
            if !active {
                Capsule()
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 3, height: 28)
            }
        }
        .frame(width: 11)
        .overlay(
            PanelResizeHandle(
                onHover: { dividerHovered = $0 },
                onDrag: { deltaX in
                    if panelDragStartWidth == nil {
                        panelDragStartWidth = CGFloat(hermesPanelWidth)
                    }
                    let proposed = (panelDragStartWidth ?? CGFloat(hermesPanelWidth)) - deltaX
                    hermesPanelWidth = Double(min(max(Self.panelMinWidth, proposed),
                                                  max(Self.panelMinWidth, maxPanelWidth)).rounded())
                },
                onEnded: { panelDragStartWidth = nil }
            )
        )
        .animation(.easeInOut(duration: 0.12), value: active)
        .accessibilityLabel("Resize agent panel")
    }

    /// A hash of everything the Hermes snapshot contains. Reading every property here makes
    /// the view observe them, so `onChange` fires on any edit (title, date, list, …), not
    /// just on inserts/deletes.
    private var dataFingerprint: Int {
        var hasher = Hasher()
        for item in activeItems + archivedItems {
            hasher.combine(item.id)
            hasher.combine(item.title)
            hasher.combine(item.kindRaw)
            hasher.combine(item.date)
            hasher.combine(item.notes)
            hasher.combine(item.isDone)
            hasher.combine(item.isArchived)
            hasher.combine(item.list?.name)
        }
        for list in lists {
            hasher.combine(list.id)
            hasher.combine(list.name)
        }
        return hasher.finalize()
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Lists") {
                ForEach(SidebarItem.smartLists) { item in
                    categoryRow(item, count: count(for: item))
                }
            }
            Section("My Lists") {
                ForEach(orderedLists) { list in
                    userListRow(list)
                }
                .onMove(perform: moveLists)
                Button {
                    newListName = ""
                    showingNewList = true
                } label: {
                    Label("New List…", systemImage: "plus.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Section("Browse") {
                categoryRow(.calendar, count: 0)
                categoryRow(.archive, count: archivedItems.count)
            }
            Section("Support") {
                ForEach(SidebarItem.support) { categoryRow($0, count: 0) }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 300)
        .navigationTitle("Planner")
        .safeAreaInset(edge: .bottom, spacing: 0) { syncStatusRow }
        .alert("New List", isPresented: $showingNewList) {
            TextField("Name", text: $newListName)
            Button("Create") { createList() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Give your list a name.")
        }
        .alert("Rename List", isPresented: renameBinding, presenting: renamingList) { _ in
            TextField("Name", text: $renameText)
            Button("Rename") { commitRename() }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Compact iCloud sync indicator pinned under the sidebar.
    private var syncStatusRow: some View {
        HStack(spacing: 6) {
            Image(systemName: syncStatus.isOn ? "checkmark.icloud.fill" : "icloud.slash")
                .font(.system(size: 11))
                .foregroundStyle(syncStatus.isOn ? Color.green : Color.orange)
            Text(syncStatus.label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .help(syncStatus.detail)
        .onAppear { syncStatus.refresh() }
    }

    private func categoryRow(_ item: SidebarItem, count: Int) -> some View {
        Label(item.title, systemImage: item.symbol)
            .badge(count)
            .tag(SidebarSelection.category(item))
    }

    private func userListRow(_ list: PlannerList) -> some View {
        Label(list.name, systemImage: "folder")
            .badge(list.activeCount)
            .tag(SidebarSelection.userList(list.id))
            .contextMenu {
                Button("Rename…") {
                    renameText = list.name
                    renamingList = list
                }
                Button("Delete", role: .destructive) {
                    context.delete(list)   // items are kept — the relationship nullifies
                }
            }
    }

    private func count(for category: SidebarItem) -> Int {
        activeItems.filter { category.contains($0) }.count
    }

    // MARK: - List management

    /// The user's lists in their manually chosen sidebar order (synced via CloudKit).
    /// Never-placed lists go to the end, oldest first.
    private var orderedLists: [PlannerList] {
        ManualOrder.sorted(lists) { $0.sortOrder }
    }

    private func moveLists(from source: IndexSet, to destination: Int) {
        ManualOrder.applyMove(orderedLists, from: source, to: destination) { list, position in
            list.sortOrder = position
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renamingList != nil }, set: { if !$0 { renamingList = nil } })
    }

    private func createList() {
        let name = newListName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let list = PlannerList(name: name)
        context.insert(list)
        selection = .userList(list.id)
    }

    private func commitRename() {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let list = renamingList, !name.isEmpty { list.name = name }
        renamingList = nil
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .category(.calendar):
            CalendarView()
        case .category(.archive):
            ArchiveView()
        case .category(.feedback):
            FeedbackView()
        case .category(.about):
            AboutView()
        default:
            MacPlannerPane(selection: selection)
        }
    }
}

/// AppKit-backed drag handle for the panel divider. Receives mouseDown/mouseDragged
/// directly from the window (SwiftUI DragGestures next to an NSViewRepresentable
/// terminal are unreliable) and owns the resize cursor via cursor rects.
private struct PanelResizeHandle: NSViewRepresentable {
    var onHover: (Bool) -> Void
    /// Cumulative horizontal delta (points) since the drag began; positive = rightwards.
    var onDrag: (CGFloat) -> Void
    var onEnded: () -> Void

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        view.onHover = onHover
        view.onDrag = onDrag
        view.onEnded = onEnded
        return view
    }

    func updateNSView(_ view: HandleView, context: Context) {
        view.onHover = onHover
        view.onDrag = onDrag
        view.onEnded = onEnded
    }

    final class HandleView: NSView {
        var onHover: ((Bool) -> Void)?
        var onDrag: ((CGFloat) -> Void)?
        var onEnded: (() -> Void)?
        private var dragStartX: CGFloat?

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self))
        }

        override func mouseEntered(with event: NSEvent) { onHover?(true) }
        override func mouseExited(with event: NSEvent) { onHover?(false) }

        override func mouseDown(with event: NSEvent) {
            dragStartX = event.locationInWindow.x
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = dragStartX else { return }
            onDrag?(event.locationInWindow.x - start)
        }

        override func mouseUp(with event: NSEvent) {
            if dragStartX != nil {
                dragStartX = nil
                onEnded?()
            }
        }
    }
}

#Preview {
    MacRootView()
        .modelContainer(for: PlannerItem.self, inMemory: true)
}
