import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

/// A fixed sidebar destination. The smart categories filter the planner pane; Calendar,
/// Archive, Feedback and About swap in their own panes. User-created lists are handled
/// separately via `SidebarSelection.userList`.
enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    // Smart lists
    case all, today, scheduled, pinned, todos, appointments, pages, goals, ideas
    // Browse
    case calendar, jobs, updates, logs, archive
    // Support
    case settings, feedback, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:          return "To-Do"
        case .today:        return "Today"
        case .scheduled:    return "Upcoming"
        case .pinned:       return "Pinned"
        case .todos:        return "To-Dos"
        case .appointments: return "Appointments"
        case .pages:        return "Pages"
        case .goals:        return "Goals"
        case .ideas:        return "Ideas"
        case .calendar:     return "Calendar"
        case .jobs:         return "Agent Jobs"
        case .updates:      return "Updates"
        case .logs:         return "Logs"
        case .archive:      return "Archive"
        case .settings:     return "Settings"
        case .feedback:     return "Feedback"
        case .about:        return "About"
        }
    }

    var symbol: String {
        switch self {
        case .all:          return "tray.full.fill"
        case .today:        return "star.fill"
        case .scheduled:    return "clock.fill"
        case .pinned:       return "pin.fill"
        case .todos:        return "checklist"
        case .appointments: return "calendar"
        case .pages:        return "doc.richtext.fill"
        case .goals:        return "target"
        case .ideas:        return "lightbulb.fill"
        case .calendar:     return "calendar.badge.clock"
        case .jobs:         return "clock.arrow.circlepath"
        case .updates:      return "doc.richtext.fill"
        case .logs:         return "list.bullet.rectangle"
        case .archive:      return "archivebox.fill"
        case .settings:     return "gearshape.fill"
        case .feedback:     return "bubble.left.and.bubble.right.fill"
        case .about:        return "info.circle.fill"
        }
    }

    /// The sidebar groups the categories into Strategy (Updates, Goals, Ideas), Tasks (To-Do, Pinned),
    /// Schedule (Today, Appointments, Calendar), Content (Pages) and Agents (Agent Jobs) — see
    /// `MacRootView.sidebar`. Pages, Goals and Ideas stay out of the work lists, so they never inflate
    /// the To-Do or Pinned counts. Not offered, but kept for persisted state and
    /// `-debugSidebar`: `.todos` (duplicated To-Do) and `.scheduled` (Upcoming — the same
    /// appointments as Appointments, which now groups them by day).
    static let support: [SidebarItem] = [.settings, .feedback, .about]

    /// Whether an active (non-archived) item belongs to this smart category.
    func contains(_ item: PlannerItem) -> Bool {
        switch self {
        case .all:
            // Labelled "To-Do": to-dos only. Appointments have their own row, so mixing
            // them in here just duplicated that list.
            return item.kind == .task
        case .today:
            guard item.isWork, let date = item.date else { return false }
            return Calendar.current.isDateInToday(date)
        case .scheduled:
            // A goal's date is a target ("by 2027"), not an upcoming event.
            return item.isWork && item.date != nil
        case .pinned:
            // Pinned is the work queue; a page or goal pinned in its own view stays there.
            return item.isPinned && item.isWork
        case .todos:
            return item.kind == .task
        case .appointments:
            return item.kind == .appointment
        case .pages:
            return item.kind == .page
        case .goals:
            return item.kind == .goal
        case .ideas:
            return item.kind == .idea
        default:
            return false
        }
    }
}

/// What is selected in the sidebar: a fixed category or one of the user's own lists.
enum SidebarSelection: Hashable {
    case category(SidebarItem)
    case userList(UUID)
    case digitalStaff(String)
}

/// Desktop root: two-column layout. Left — smart categories plus the user's own lists
/// (create / rename / delete). Right — the planner pane (item list + chatbot-style capture
/// bar) or a dedicated pane.
struct MacRootView: View {
    @Environment(\.modelContext) private var context
    /// The appearance actually on screen (follows `AppearanceController` via NSApp).
    @Environment(\.colorScheme) private var colorScheme

    /// Planner opens on Updates (today's reports, Morning Brief first).
    @State private var selection: SidebarSelection = .category(.updates)
    @State private var staffRoster: [String: AgentProfile] = [:]
    @State private var showingNewList = false
    @State private var newListName = ""
    /// When set, the New List alert creates a sub-list under this parent.
    @State private var newListParent: PlannerList?

    /// Parent lists the user has opened, stored locally as comma-joined UUIDs — per-device UI
    /// state, not synced data. Lists are collapsed unless listed here, so lists that arrive
    /// later (iCloud sync, agent `newlist`) start collapsed too. (The old `collapsedLists`
    /// key was filled at launch before the @Query loaded, which left everything expanded.)
    @AppStorage("expandedLists") private var expandedListsRaw = ""

    /// Who "I" am, for the assigned-to filter (shared with the planner pane and iPhone app).
    @AppStorage("ownerName") private var ownerName = "Alfred"
    /// Colours the folders under ATO PROJECTS (see `ATOStatus`).
    @AppStorage(ATOStatus.storageKey) private var atoStatusRaw = ""

    private var expandedLists: Set<UUID> {
        Set(expandedListsRaw.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }

    private func setExpanded(_ set: Set<UUID>) {
        expandedListsRaw = set.map(\.uuidString).joined(separator: ",")
    }

    /// Everything not explicitly expanded — the shape `ListHierarchy.rows` wants.
    private var collapsedLists: Set<UUID> {
        Set(lists.map(\.id)).subtracting(expandedLists)
    }

    /// Accordion toggle: collapsing a list also folds its sub-lists; expanding one folds its
    /// open siblings (and their sub-lists), so only one branch under a parent is open.
    private func toggleCollapsed(_ id: UUID) {
        guard let list = lists.first(where: { $0.id == id }) else { return }
        var set = expandedLists
        if set.contains(id) {
            set.subtract(list.subtreeIDs)
        } else {
            let siblings = list.parent?.children ?? lists.filter { $0.parent == nil }
            for sibling in siblings where sibling.id != id {
                set.subtract(sibling.subtreeIDs)
            }
            set.insert(id)
        }
        setExpanded(set)
    }

    /// Opens a list and its ancestors, folding every other branch — what clicking a folder does.
    private func reveal(_ list: PlannerList) {
        var set = Set<UUID>()
        var node: PlannerList? = list
        while let current = node {
            set.insert(current.id)
            node = current.parent
        }
        setExpanded(set)
    }

    /// Lists that can actually collapse — only those with sub-lists.
    private var collapsibleListIDs: [UUID] {
        lists.filter { !($0.children ?? []).isEmpty }.map(\.id)
    }

    /// True when at least one parent list is still expanded (so "Collapse All" has work).
    private var hasExpandedLists: Bool {
        let expanded = expandedLists
        return collapsibleListIDs.contains { expanded.contains($0) }
    }

    private func collapseAllLists() {
        expandedListsRaw = ""
    }

    private func expandAllLists() {
        setExpanded(Set(collapsibleListIDs))
    }

    private func openWorkforce(_ list: PlannerList) {
        reveal(list)
        selection = .userList(list.id)
        UserDefaults.standard.set(false, forKey: "agentPaneShowsItems")
    }

    /// The list behind a sidebar selection; staff lists are tagged by name, and roster-only
    /// staff rows have no list (nil), which leaves the open branch alone.
    private func list(for selection: SidebarSelection) -> PlannerList? {
        switch selection {
        case .userList(let id):
            return lists.first { $0.id == id }
        case .digitalStaff(let id):
            return lists.first {
                $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == id
            }
        default:
            return nil
        }
    }

    private func selection(for list: PlannerList) -> SidebarSelection {
        let id = list.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if staffRoster[id] != nil { return .digitalStaff(id) }
        return .userList(list.id)
    }
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

    /// Sidebar list currently under a dragged item — drives the drop highlight.
    @State private var dropTargetListID: UUID?

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
                            selection = .category(.calendar)
                        } label: {
                            Image(systemName: "calendar")
                        }
                        .keyboardShortcut("k", modifiers: [.command, .shift])
                        .help("Open the Calendar (⇧⌘K)")
                        .accessibilityLabel("Open Calendar")
                    }
                    ToolbarItem(placement: .automatic) {
                        Button {
                            AppearanceController.shared.toggle()
                        } label: {
                            Image(systemName: colorScheme == .dark ? "sun.max" : "moon")
                        }
                        .help(colorScheme == .dark ? "Switch to Light mode (⇧⌘D)" : "Switch to Dark mode (⇧⌘D)")
                        .accessibilityLabel(colorScheme == .dark ? "Switch to Light mode" : "Switch to Dark mode")
                    }
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
        // Clicking a folder opens it and folds the others, same as its chevron.
        .onChange(of: selection) {
            if let list = list(for: selection) {
                withAnimation(.easeInOut(duration: 0.15)) { reveal(list) }
            }
        }
        .onChange(of: lists.count) {
            // If the selected user list was deleted (locally or via sync), fall back to Updates.
            if case .userList(let id) = selection, !lists.contains(where: { $0.id == id }) {
                selection = .category(.updates)
            }
        }
        // Hermes agent bridge: keep the workspace + JSON snapshot current, and execute the
        // planner:// commands the agent issues from the terminal panel (see HermesBridge).
        .task {
            // Start with every sub-list tucked away; expand by chevron as needed.
            collapseAllLists()
            staffRoster = AgentRoster.load()
            PowerSettings.registerLoginItemOnce()
            HermesBridge.prepareWorkspace()
            // All four agents run from launch, so each is ready (and listening) even
            // before the panel is opened.
            AgentPanelTabs.shared.startAll()
            // One-time repair for items captured inside someone's list before the capture
            // bar filled in "Assign to". Runs at launch rather than behind a button so it
            // can't be missed; the flag keeps it to a single pass.
            AssigneeBackfill.runOnce(context: context)
            HermesBridge.writeSnapshot(context: context)
            HermesBridge.startInbox(context: context)
            #if DEBUG
            // `-debugSidebar calendar` opens a pane directly (screenshots / UI checks).
            if let raw = UserDefaults.standard.string(forKey: "debugSidebar"),
               let item = SidebarItem(rawValue: raw) {
                selection = .category(item)
            }
            // `-debugList Atlas` opens a user list by name.
            if let name = UserDefaults.standard.string(forKey: "debugList"),
               let list = lists.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                selection = .userList(list.id)
            }
            #endif
            WhatsAppReminders.shared.start(context: context)
        }
        .background(HermesSnapshotObserver())
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

    /// Active items per list, sub-lists rolled up into their parents — one pass over the items
    /// instead of every row walking its subtree (which also faulted in archived items).
    private var subtreeActiveCounts: [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for item in activeItems {
            var node = item.list
            while let list = node {
                counts[list.id, default: 0] += 1
                node = list.parent
            }
        }
        return counts
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            // Worked out once per render, not once per row. Projects and the two workforce trees get
            // their own sections; My Lists holds the rest. Drags map back onto `allRows` (moveRows).
            let collapsed = sidebarCollapsed
            let counts = subtreeActiveCounts
            let allRows = ListHierarchy.rows(lists, collapsed: collapsed)
            // Strategy, Workforce, Schedule, Projects, Tasks, Content, Logs, then the user's own lists.
            Section("Strategy") {
                // The agents' reports (Morning Brief etc.), opened in the Browser tab. First row
                // and the page Planner opens on.
                Label(SidebarItem.updates.title, systemImage: SidebarItem.updates.symbol)
                    .badge(todaysUpdates)
                    .tag(SidebarSelection.category(.updates))
                categoryRow(.goals, count: count(for: .goals))
                categoryRow(.ideas, count: count(for: .ideas))
            }
            Section("Workforce") {
                // Human Workforce (HR org chart, interns), Trainers (trainer directory), Agent Workforce
                // (the Digital Workforce list: agents + org chart), the agents' scheduled jobs, then Hermes.
                ForEach(Self.workforceRoots, id: \.self) { name in
                    if let root = rootList(name) {
                        let tree = treeRows(root, in: allRows)
                        ForEach(tree) { row in
                            listRows(row, depth: row.depth, collapsed: collapsed, counts: counts)
                        }
                        .onMove { moveRows(tree, in: allRows, from: $0, to: $1) }
                    }
                }
                // Scheduled background jobs (agents, cron) — not planner items, so no count.
                Label(SidebarItem.jobs.title, systemImage: SidebarItem.jobs.symbol)
                    .tag(SidebarSelection.category(.jobs))
                // Switches to the Hermes desktop app (sessions, bots, scheduled jobs) — an
                // action, not a pane, so it has no selection tag.
                Button(action: HermesDesktop.open) {
                    HStack {
                        Label("Hermes Agent", systemImage: "arrow.up.forward.app")
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Switch to the Hermes desktop app")
            }
            Section("Schedule") {
                categoryRow(.today, count: count(for: .today))
                // Appointments grouped by day (it absorbed the old Upcoming view).
                categoryRow(.appointments, count: count(for: .appointments))
                categoryRow(.calendar, count: upcomingAppointmentCount)
            }
            if let projects = rootList(Self.projectsRoot) {
                let tree = Array(treeRows(projects, in: allRows).dropFirst())
                Section("Projects") {
                    // The Projects folder's own items (and its whole count); its sub-lists follow.
                    Label("All Projects", systemImage: "folder")
                        .badge(counts[projects.id] ?? 0)
                        .tag(selection(for: projects))
                    ForEach(tree) { row in
                        listRows(row, depth: row.depth - 1, collapsed: collapsed, counts: counts)
                    }
                    .onMove { moveRows(tree, in: allRows, from: $0, to: $1) }
                }
            }
            Section("Tasks") {
                ForEach([SidebarItem.all, .pinned]) { categoryRow($0, count: count(for: $0)) }
            }
            Section("Content") {
                categoryRow(.pages, count: count(for: .pages))
            }
            Section("Logs") {
                // Every agent report that isn't a brief or weekly update (checks, scans, watchers,
                // monitors), kept out of Updates. No badge, so it doesn't pull attention.
                Label(SidebarItem.logs.title, systemImage: SidebarItem.logs.symbol)
                    .tag(SidebarSelection.category(.logs))
            }
            Section {
                let mine = myListRows(allRows)
                ForEach(mine) { row in
                    listRows(row, depth: row.depth, collapsed: collapsed, counts: counts)
                }
                .onMove { moveRows(mine, in: allRows, from: $0, to: $1) }
                Button {
                    newListName = ""
                    newListParent = nil
                    showingNewList = true
                } label: {
                    Label("New List…", systemImage: "plus.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } header: {
                HStack(spacing: 4) {
                    Text("My Lists")
                    Spacer(minLength: 0)
                    // One control that flips between collapsing and expanding every group.
                    if !collapsibleListIDs.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                if hasExpandedLists { collapseAllLists() } else { expandAllLists() }
                            }
                        } label: {
                            Image(systemName: hasExpandedLists
                                  ? "arrow.down.right.and.arrow.up.left"
                                  : "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 20, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(hasExpandedLists ? "Collapse all lists" : "Expand all lists")
                        .accessibilityLabel(hasExpandedLists ? "Collapse all lists" : "Expand all lists")
                    }
                }
            }
            Section("Browse") {
                categoryRow(.archive, count: archivedItems.count)
            }
            Section("Support") {
                ForEach(SidebarItem.support) { categoryRow($0, count: 0) }
            }
        }
        .listStyle(.sidebar)
        // Wide max: nested lists indent deeply and long client names otherwise truncate.
        .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 560)
        .navigationTitle("Planner")
        .safeAreaInset(edge: .bottom, spacing: 0) { syncStatusRow }
        .alert(newListParent == nil ? "New List" : "New Sub-list", isPresented: $showingNewList) {
            TextField("Name", text: $newListName)
            Button("Create") { createList() }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let parent = newListParent {
                Text("Give the sub-list under “\(parent.name)” a name.")
            } else {
                Text("Give your list a name.")
            }
        }
        .alert("Rename List", isPresented: renameBinding, presenting: renamingList) { _ in
            TextField("Name", text: $renameText)
            Button("Rename") { commitRename() }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Compact iCloud sync indicator pinned under the sidebar.
    /// "Planner 2.9 (58)": the version and build, shown at the bottom left of the sidebar.
    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Planner \(version) (\(build))"
    }

    private var syncStatusRow: some View {
        HStack(spacing: 6) {
            Image(systemName: syncStatus.isOn ? "checkmark.icloud.fill" : "icloud.slash")
                .font(.system(size: 11))
                .foregroundStyle(syncStatus.isOn ? Color.green : Color.orange)
            Text(syncStatus.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(appVersion)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
                .help("Planner version (build)")
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

    private func userListRow(_ list: PlannerList, depth: Int, isCollapsed: Bool, count: Int) -> some View {
        HStack(spacing: 4) {
            if !(list.children ?? []).isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { toggleCollapsed(list.id) }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        // A full-height hit area — the bare 9pt glyph was too small to click,
                        // so clicks fell through to row selection instead of collapsing.
                        .frame(width: 18, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCollapsed ? "Expand \(list.name)" : "Collapse \(list.name)")
            }
            if list.name.caseInsensitiveCompare("Digital Workforce") == .orderedSame {
                Button { openWorkforce(list) } label: {
                    Label("Agent Workforce", systemImage: "folder")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Agent Workforce")
                .help("Expand the staff and open the interactive org chart")
            } else if let status = ATOStatus.of(list, in: atoStatusRaw) {
                Label {
                    Text(list.name)
                } icon: {
                    Image(systemName: "folder.fill").foregroundStyle(status.color)
                }
                .help("ATO application: \(status.title)")
                .accessibilityLabel("\(list.name), ATO application \(status.title)")
            } else {
                Label(list.name, systemImage: "folder")
            }
            if list.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Pinned")
            }
        }
            .padding(.leading, CGFloat(depth) * 28)
            .badge(count)
            .tag(selection(for: list))
            .onDrop(of: [UTType.plannerItem],
                    isTargeted: Binding(
                        get: { dropTargetListID == list.id },
                        set: { targeted in
                            if targeted { dropTargetListID = list.id }
                            else if dropTargetListID == list.id { dropTargetListID = nil }
                        })) { providers in
                load(providers) { ids in move(ids, to: list) }
                return true
            }
            .listRowBackground(
                dropTargetListID == list.id
                    ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.25))
                    : nil
            )
            .contextMenu {
                Button(list.isPinned ? "Unpin" : "Pin to Top") {
                    withAnimation { list.isPinned.toggle() }
                }
                Button("New Sub-list…") {
                    newListName = ""
                    newListParent = list
                    showingNewList = true
                }
                Menu("Move to") {
                    if list.parent != nil {
                        Button("Top Level") { reparent(list, under: nil) }
                    }
                    ForEach(ListHierarchy.rows(lists).filter {
                        $0.list.id != list.id && $0.list.id != list.parent?.id
                            && !$0.list.isDescendant(of: list)
                    }) { row in
                        Button(String(repeating: "  ", count: row.depth) + row.list.name) {
                            reparent(list, under: row.list)
                        }
                    }
                }
                Button("Rename…") {
                    renameText = list.name
                    renamingList = list
                }
                if list.isATOProject {
                    Menu("ATO Status") {
                        ForEach(ATOStatus.allCases) { status in
                            Button(status.title) {
                                atoStatusRaw = ATOStatus.encode(atoStatusRaw, setting: status, for: list)
                            }
                        }
                        Divider()
                        Button("No Status") {
                            atoStatusRaw = ATOStatus.encode(atoStatusRaw, setting: nil, for: list)
                        }
                    }
                }
                Divider()
                Button("Delete", role: .destructive) {
                    context.delete(list)   // items + sub-lists are kept — relationships nullify
                }
            }
    }

    private func reparent(_ list: PlannerList, under parent: PlannerList?) {
        list.parent = parent
        list.sortOrder = 0   // never-placed → joins the end of its new sibling group
    }

    /// Badge count for a smart category. Must apply the SAME owner filter the planner pane
    /// uses, or the badge advertises rows the pane won't show (delegated items).
    private func count(for category: SidebarItem) -> Int {
        // Goals: the ones still being worked towards (achieved goals stay listed, ticked).
        activeItems.filter { category.contains($0) && $0.isMine(ownerName: ownerName)
            && !(category == .goals && $0.isDone) }.count
    }

    @ObservedObject private var agentBrowser = AgentBrowser.shared

    /// Updates badge: reports published today.
    private var todaysUpdates: Int {
        let today = Date().formatted(.iso8601.year().month().day())
        return agentBrowser.reports.filter {
            $0.date == today && ReportPresentation.isUpdate(file: $0.file, title: $0.displayTitle)
        }.count
    }

    /// Calendar badge: appointments from today onwards (everyone's — the calendar shows all).
    private var upcomingAppointmentCount: Int {
        let start = Calendar.current.startOfDay(for: Date())
        return activeItems.filter { $0.kind == .appointment && ($0.date ?? .distantPast) >= start }.count
    }

    // MARK: - List management

    /// Drag over the flattened outline: reorders siblings, and dropping into a group's
    /// children nests the dragged list there (see ListHierarchy.applyMove).
    /// Collects ids from concurrent `loadObject` callbacks.
    private final class IDBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [UUID] = []
        var ids: [UUID] { lock.withLock { storage } }
        func append(_ id: UUID) { lock.withLock { storage.append(id) } }
    }

    /// Resolve dropped item providers into ids, then hand them back on the main actor —
    /// `loadObject` calls back on a background queue, and SwiftData writes must be on main.
    private func load(_ providers: [NSItemProvider],
                      then handle: @escaping ([UUID]) -> Void) {
        let group = DispatchGroup()
        let box = IDBox()
        for provider in providers
        where provider.canLoadObject(ofClass: PlannerItemDragPayload.self) {
            group.enter()
            _ = provider.loadObject(ofClass: PlannerItemDragPayload.self) { payload, _ in
                if let payload = payload as? PlannerItemDragPayload { box.append(payload.id) }
                group.leave()
            }
        }
        group.notify(queue: .main) { handle(box.ids) }
    }

    /// Reassign dropped items to `list`.
    private func move(_ ids: [UUID], to list: PlannerList) {
        let ids = Set(ids)
        guard !ids.isEmpty else { return }
        // Don't filter out items already in this list: one may sit in the right list with a
        // stale assignee (e.g. moved before this rule existed), and re-dropping it should
        // still fix the owner.
        let items = activeItems.filter { ids.contains($0.id) }
        guard !items.isEmpty else { return }
        // Moving into someone's list reassigns the work to them — same rule that auto-fills
        // "Assign to" when adding an item inside that list. Lists that don't name a person
        // (category folders like "Clients") leave the existing assignee alone.
        let newAssignee = list.derivedAssignee
        withAnimation {
            for item in items {
                item.list = list
                if let newAssignee { item.assignedTo = newAssignee }
            }
            dropTargetListID = nil
        }
    }

    // MARK: - Sidebar list sections

    /// Root lists that get their own sidebar section instead of sitting in My Lists.
    static let projectsRoot = "Projects"
    /// In this order: Human Workforce, Trainers, then Agent Workforce (the list is named "Digital Workforce").
    static let workforceRoots = ["Human Workforce", "Trainers", "Digital Workforce"]

    private func rootList(_ name: String) -> PlannerList? {
        lists.first { $0.parent == nil && $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The collapsed set the sidebar draws with. The Projects root has no row of its own (its
    /// sub-lists are the Projects section), so it always counts as open.
    private var sidebarCollapsed: Set<UUID> {
        var set = collapsedLists
        if let projects = rootList(Self.projectsRoot) { set.remove(projects.id) }
        return set
    }

    /// One root's visible rows (root first), cut from the full outline.
    private func treeRows(_ root: PlannerList, in all: [ListHierarchy.Row]) -> [ListHierarchy.Row] {
        guard let start = all.firstIndex(where: { $0.list.id == root.id }) else { return [] }
        let end = all[(start + 1)...].firstIndex(where: { $0.depth == 0 }) ?? all.endIndex
        return Array(all[start..<end])
    }

    /// Rows for My Lists: every tree except the ones with their own section.
    private func myListRows(_ all: [ListHierarchy.Row]) -> [ListHierarchy.Row] {
        let own = ([Self.projectsRoot] + Self.workforceRoots).compactMap { rootList($0)?.id }
        var result: [ListHierarchy.Row] = []
        var skipping = false
        for row in all {
            if row.depth == 0 { skipping = own.contains(row.list.id) }
            if !skipping { result.append(row) }
        }
        return result
    }

    /// A list row, plus (under an open Digital Workforce) the agents that have no list of their own.
    @ViewBuilder
    private func listRows(_ row: ListHierarchy.Row, depth: Int, collapsed: Set<UUID>,
                          counts: [UUID: Int]) -> some View {
        userListRow(row.list, depth: depth,
                    isCollapsed: collapsed.contains(row.list.id),
                    count: counts[row.list.id] ?? 0)
        if row.list.name.caseInsensitiveCompare("Digital Workforce") == .orderedSame,
           !collapsed.contains(row.list.id) {
            let listed = Set((row.list.children ?? []).map { $0.name.lowercased() })
            ForEach(AgentRoster.staffIDs.filter { !listed.contains($0) }, id: \.self) { id in
                if let agent = staffRoster[id] {
                    Label(agent.displayName, systemImage: "person.crop.circle")
                        .padding(.leading, CGFloat(depth + 1) * 28)
                        .tag(SidebarSelection.digitalStaff(id))
                        .accessibilityLabel("Chat with \(agent.displayName)")
                }
            }
        }
    }

    /// `onMove` inside one section: its indices count only that section's rows, so map the
    /// dragged row and the drop point back onto the full outline (same collapsed set the sidebar
    /// draws with), where ListHierarchy works out the new parent and sibling order.
    private func moveRows(_ shown: [ListHierarchy.Row], in all: [ListHierarchy.Row],
                          from source: IndexSet, to destination: Int) {
        guard let first = source.first, first < shown.count else { return }
        func index(_ row: ListHierarchy.Row) -> Int? { all.firstIndex { $0.id == row.id } }
        guard let from = index(shown[first]) else { return }
        let to: Int
        if destination < shown.count, let i = index(shown[destination]) {
            to = i
        } else if let last = shown.last, let i = index(last) {
            to = i + 1
        } else {
            return
        }
        ListHierarchy.applyMove(all, from: IndexSet(integer: from), to: to)
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renamingList != nil }, set: { if !$0 { renamingList = nil } })
    }

    private func createList() {
        let name = newListName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let list = PlannerList(name: name, parent: newListParent)
        context.insert(list)
        // Reveal the new sub-list if its parent was collapsed.
        if let parent = newListParent { reveal(parent) }
        newListParent = nil
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
            MacCalendarPane()
        case .category(.jobs):
            MacSchedulePane()
        case .category(.updates):
            MacUpdatesPane(feed: .updates)
        case .category(.logs):
            MacUpdatesPane(feed: .logs)
        case .category(.archive):
            ArchiveView()
        case .category(.settings):
            MacSettingsPane()
        case .category(.feedback):
            FeedbackView()
        case .category(.about):
            AboutView()
        default:
            MacPlannerPane(selection: selection,
                           onOpenList: { selection = .userList($0) },
                           onOpenAgent: { selection = .digitalStaff($0) })
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

/// The Hermes desktop app (Nous Research, an Electron build in the Hermes agent checkout).
/// Brought to the front when it's running, otherwise launched.
enum HermesDesktop {
    static let bundleID = "com.nousresearch.hermes"

    /// Where the desktop app is built, used when LaunchServices doesn't know the bundle id.
    /// `/Applications/Hermes.app` is only the Hermes-Setup launcher, so it is the last resort.
    private static let fallbackPaths = [
        "~/.hermes/hermes-agent/apps/desktop/release/mac-arm64/Hermes.app",
        "/Applications/Hermes.app",
    ]

    static func open() {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            running.unhide()
            running.activate()
            return
        }
        let fm = FileManager.default
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            ?? fallbackPaths
                .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                .first { fm.fileExists(atPath: $0.path) }
        guard let url else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Keeps the Hermes snapshot current. Its own view, so hashing every item happens only when
/// items change — in `MacRootView` it ran on every render, i.e. on every sidebar click.
private struct HermesSnapshotObserver: View {
    @Environment(\.modelContext) private var context
    @Query private var items: [PlannerItem]
    @Query private var lists: [PlannerList]

    /// A hash of everything the snapshot contains. Reading every property here makes the view
    /// observe them, so it updates on any edit (title, date, list, …), not just inserts/deletes.
    private var fingerprint: Int {
        var hasher = Hasher()
        for item in items {
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

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .task(id: fingerprint) {
                // A pause so a burst of changes (an iCloud import) writes the file once.
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                HermesBridge.writeSnapshot(context: context)
            }
    }
}
