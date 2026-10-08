import SwiftUI
import SwiftData

/// The main planner screen: two top tabs — To-Do and Appointment — each with its own pair
/// of sub-tabs (To-Do: All Tasks / Pinned Tasks; Appointment: Today / Upcoming). A page
/// never mixes both kinds. Includes the **voice add** mic button and a manual add button.
struct TodoListView: View {
    /// Which top tab is open — To-Do or Appointment.
    @State private var mode: PlannerKind = .task

    @Environment(\.modelContext) private var context

    // Active items only; checked items auto-archive and disappear from here.
    @Query(
        filter: #Predicate<PlannerItem> { !$0.isArchived },
        sort: [SortDescriptor(\PlannerItem.date), SortDescriptor(\PlannerItem.createdAt, order: .reverse)]
    )
    private var items: [PlannerItem]

    @Query(sort: \PlannerList.createdAt) private var lists: [PlannerList]

    @Environment(\.undoManager) private var undoManager

    @State private var filter: PlannerFilter = .category(.all)
    @State private var showingAdd = false
    @State private var showingLists = false

    // Chatbot capture bar (mirrors the Mac pane): type or dictate, the assistant drafts
    // and saves the entry, replying inline with Undo.
    @State private var speech: SpeechRecognizer?
    @State private var input = ""
    @State private var isThinking = false
    @State private var deletingItem: PlannerItem?
    @FocusState private var inputFocused: Bool

    private var isListening: Bool { speech?.isListening ?? false }
    @State private var editingItem: PlannerItem?
    /// Keyword filter over active items (archived items are never searched).
    @State private var searchText = ""

    /// Who "I" am, for the assigned-to filter. Items assigned to this name (or to nobody)
    /// stay in the smart views; anything delegated to someone else is filtered out.
    @AppStorage("ownerName") private var ownerName = "Alfred"

    init() {
        #if DEBUG
        // Screenshot helper: `-openUpcoming` opens Appointment ▸ Upcoming at launch.
        if CommandLine.arguments.contains("-openUpcoming") {
            _mode = State(initialValue: .appointment)
            _filter = State(initialValue: .category(.scheduled))
        }
        #endif
    }

    /// The open user list, when the filter is one.
    private var currentList: PlannerList? {
        guard case .list(let id) = filter else { return nil }
        return lists.first { $0.id == id }
    }

    private var modeTitle: String { mode == .task ? "To-Dos" : "Appointments" }

    private var navigationTitle: String {
        if case .list = filter, let list = currentList { return list.name }
        return "Planner"
    }

    /// Everything of this tab's kind (the tab never mixes to-dos and appointments).
    private var kindItems: [PlannerItem] { items.filter { $0.kind == mode } }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var visibleItems: [PlannerItem] {
        // A search looks across every active item of this tab's kind, not just the current
        // filter — otherwise you'd have to know which list something is in to find it.
        // Archived items are never searched (the query excludes them already).
        if isSearching { return kindItems.filter { $0.matches(searchText) } }

        switch filter {
        case .category(let c):
            // Smart views are *your* queue: your own items (unassigned, or assigned to
            // you) only. Work delegated to someone else is hidden here so it doesn't
            // drown out yours — open that person's list to see theirs.
            return kindItems.filter { c.contains($0) && $0.isMine(ownerName: ownerName) }
        case .list:
            // A parent list shows its own items plus everything in its sub-lists —
            // including assigned ones, since that's the point of opening someone's list.
            let ids = currentList?.subtreeIDs ?? []
            return kindItems.filter { item in
                guard let listID = item.list?.id else { return false }
                return ids.contains(listID)
            }
        }
    }

    /// Rows in manual drag order (synced via CloudKit through `sortOrder`, so the Mac app
    /// shows the same arrangement); never-placed rows keep their date order, after the
    /// placed ones. Same for the list chips below.
    /// Visible rows in manual drag order, pinned first.
    /// To-dos also sort by priority (Critical → Low) inside each pinned partition.
    private var rows: [PlannerItem] {
        mode == .task
            ? ManualOrder.sortedPinnedByPriority(visibleItems, pinned: { $0.isPinned },
                                                 priority: { $0.priorityRaw },
                                                 position: { $0.sortOrder })
            : ManualOrder.sortedPinnedFirst(visibleItems,
                                            pinned: { $0.isPinned }, position: { $0.sortOrder })
    }
    private func moveItems(_ ordered: [PlannerItem], from source: IndexSet, to destination: Int) {
        ManualOrder.applyMove(ordered, from: source, to: destination) { item, position in
            item.sortOrder = position
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                modeTabBar
                Divider()
                subTabBar
                Divider()
                duplicateBanner
                if visibleItems.isEmpty {
                    emptyState
                } else {
                    itemList
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: mode == .task ? "Search to-dos" : "Search appointments")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingLists = true } label: {
                        Image(systemName: "folder.badge.gearshape")
                    }
                    .accessibilityLabel("Manage lists")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { withAnimation { undoManager?.undo() } } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .disabled(!(undoManager?.canUndo ?? false))
                    .accessibilityLabel("Undo")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAdd = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add item")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { captureBar }
            .sheet(isPresented: $showingAdd) {
                // Default the form to this tab's kind.
                AddItemView(prefill: ParsedEntry(title: "", kind: mode, date: nil),
                            defaultList: currentList)
            }
            .sheet(isPresented: $showingLists) { ListsManagerView() }
            .sheet(item: $editingItem) { AddItemView(item: $0) }
            .confirmationDialog("Delete this item?", isPresented: Binding(
                get: { deletingItem != nil },
                set: { if !$0 { deletingItem = nil } }
            ), titleVisibility: .visible, presenting: deletingItem) { item in
                Button("Delete", role: .destructive) {
                    withAnimation { context.delete(item) }
                    deletingItem = nil
                }
                Button("Cancel", role: .cancel) { deletingItem = nil }
            } message: { item in
                Text("“\(item.title)” will be removed permanently.")
            }
            .onChange(of: lists.count) {
                // If the selected list was deleted (locally or via sync), fall back to All.
                if case .list(let id) = filter, !lists.contains(where: { $0.id == id }) {
                    filter = .category(.all)
                }
            }
        }
    }

    // MARK: - Top tabs (To-Do | Appointment) and their sub-tabs

    /// The sub-views of the open top tab. To-Do offers All Tasks and Pinned Tasks;
    /// Appointment offers Today and Upcoming ("scheduled" = anything with a date, broken
    /// down by day).
    private var subTabs: [(category: PlannerCategory, label: String)] {
        mode == .task
            ? [(.all, "All Tasks"), (.pinned, "Pinned Tasks")]
            : [(.today, "Today"), (.scheduled, "Upcoming")]
    }

    private func select(_ kind: PlannerKind) {
        withAnimation {
            mode = kind
            filter = .category(kind == .task ? .all : .today)
        }
    }

    private var modeTabBar: some View {
        HStack(spacing: 0) {
            ForEach(PlannerKind.allCases) { kind in
                Button { select(kind) } label: {
                    VStack(spacing: 7) {
                        HStack(spacing: 6) {
                            Image(systemName: kind.symbol)
                            Text(kind == .task ? "To-Do" : "Appointment")
                        }
                        .font(.subheadline.weight(mode == kind ? .semibold : .regular))
                        .foregroundStyle(mode == kind ? Theme.accent : Color.secondary)
                        // Underline indicator marks the open tab.
                        Capsule()
                            .fill(mode == kind ? Theme.accent : Color.clear)
                            .frame(height: 3)
                            .padding(.horizontal, 24)
                    }
                    .padding(.top, 10)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(mode == kind ? .isSelected : [])
            }
        }
        .background(Theme.bg)
    }

    private var subTabBar: some View {
        HStack(spacing: 8) {
            ForEach(subTabs, id: \.category) { tab in
                chip(title: tab.label,
                     symbol: tab.category.symbol,
                     // Same rule as `visibleItems`, so the badge matches the rows.
                     count: kindItems.filter { tab.category.contains($0) && $0.isMine(ownerName: ownerName) }.count,
                     isSelected: filter == .category(tab.category)) {
                    withAnimation { filter = .category(tab.category) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.bg)
    }

    private func chip(title: String, symbol: String, count: Int,
                      isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.caption)
                Text(title)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                }
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isSelected ? Theme.accent : Theme.card, in: Capsule())
            .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Duplicate audit (mirrors the Mac pane's banner)

    /// Same-title-same-day clusters among this tab's active items (multi-day courses are
    /// not duplicates and are never flagged — see DuplicateAudit).
    private var duplicateGroups: [DuplicateAudit.Group] {
        DuplicateAudit.findDuplicates(in: kindItems, kind: mode)
    }

    /// Quiet banner offering to archive redundant copies. Only appears when there are any.
    @ViewBuilder
    private var duplicateBanner: some View {
        let groups = duplicateGroups
        if !groups.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(groups.count == 1
                         ? "1 possible duplicate"
                         : "\(groups.count) possible duplicates")
                        .font(.callout.weight(.medium))
                    Text(groups.map { "“\($0.title)” (\($0.dayLabel))" }
                            .joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Button("Archive extras") {
                    withAnimation { groups.forEach(DuplicateAudit.resolve) }
                }
                .font(.callout.weight(.medium))
                .accessibilityHint("Keeps the original of each and archives the later copies — nothing is deleted")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.12))
            Divider()
        }
    }

    // MARK: - Items

    /// Upcoming is broken down by date instead of one hand-ordered list (search results
    /// stay flat).
    private var showsDaySections: Bool {
        filter == .category(.scheduled) && !isSearching
    }

    private var itemList: some View {
        List {
            if showsDaySections {
                // Date order is the point here, so there's no drag-to-rearrange.
                ForEach(DaySections.group(visibleItems)) { section in
                    Section {
                        ForEach(section.items) { row($0, showsGrip: false) }
                            .onDelete { delete(section.items, at: $0) }
                    } header: {
                        Text(section.title)
                            .foregroundStyle(section.day == nil ? Color.red : Color.secondary)
                    }
                }
            } else {
                let ordered = rows
                ForEach(ordered) { row($0) }
                    .onDelete { delete(ordered, at: $0) }
                    .onMove { moveItems(ordered, from: $0, to: $1) }
            }
        }
        // Pull down to nudge iCloud: pushes pending changes up and re-checks the account.
        .refreshable { CloudSyncStatus.shared.nudge(context: context) }
    }

    private func row(_ item: PlannerItem, showsGrip: Bool = true) -> some View {
        HStack(spacing: 10) {
            ItemRow(item: item) {
                withAnimation { item.toggleDone() }   // checking auto-archives
            } onEdit: {
                editingItem = item
            }
            // Priority flag on to-dos: tap to set Critical / High / Medium / Low.
            if item.kind == .task {
                PriorityMenuButton(item: item)
            }
            // Tap the pin to pin/unpin — solid orange when pinned, faint outline when not.
            Button {
                withAnimation { item.isPinned.toggle() }
            } label: {
                Image(systemName: item.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 15))
                    .foregroundStyle(item.isPinned ? AnyShapeStyle(.orange)
                                                   : AnyShapeStyle(.secondary.opacity(0.5)))
                    .frame(width: 28, height: 28)   // comfortable tap target
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(item.isPinned ? "Unpin" : "Pin to top")
            // Deleting is permanent, so the tap asks first.
            Button {
                deletingItem = item
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .frame(width: 28, height: 28)   // comfortable tap target
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Delete")
            // Drag affordance — hold and drag anywhere on the row to rearrange.
            if showsGrip {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                withAnimation { item.isPinned.toggle() }
            } label: {
                Label(item.isPinned ? "Unpin" : "Pin",
                      systemImage: item.isPinned ? "pin.slash.fill" : "pin.fill")
            }
            .tint(.orange)
        }
        .contextMenu {
            if item.kind == .task {
                Menu("Priority") {
                    ForEach(PlannerPriority.ordered) { p in
                        Button {
                            withAnimation { item.setPriority(p) }
                        } label: {
                            Label(p.title, systemImage: item.priority == p ? "checkmark" : p.symbol)
                        }
                    }
                }
            }
            // iPhone equivalent of the Mac's drag-to-sidebar: same move, same
            // auto-reassign, without a drag target to aim at.
            Menu("Move to List") {
                ForEach(ListHierarchy.rows(lists)) { row in
                    Button(String(repeating: "  ", count: row.depth) + row.list.name) {
                        move(item, to: row.list)
                    }
                    .disabled(item.list?.id == row.list.id)
                }
            }
            Button(item.isPinned ? "Unpin" : "Pin to Top") {
                withAnimation { item.isPinned.toggle() }
            }
            Button("Edit…") { editingItem = item }
            Divider()
            Button("Delete", role: .destructive) { deletingItem = item }
        }
    }

    /// Move one item into `list`, reassigning it to that list's owner — mirrors the Mac
    /// drop behaviour so both platforms agree on what a move means.
    private func move(_ item: PlannerItem, to list: PlannerList) {
        let newAssignee = list.derivedAssignee
        withAnimation {
            item.list = list
            if let newAssignee { item.assignedTo = newAssignee }
        }
    }

    // MARK: - Chatbot capture bar (mirrors the Mac pane, pinned to the bottom)

    private var captureBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isThinking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Drafting…").font(.footnote).foregroundStyle(.secondary)
                }
            }
            // No per-add confirmation: the new row appearing in the list above IS the
            // feedback, and the toolbar's global Undo (↺) reverts it like any other change.

            HStack(spacing: 10) {
                TextField(isListening ? "Listening…" : "e.g. “Lunch with Sam tomorrow 1pm”",
                          text: $input, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Theme.card, in: Capsule())
                    .focused($inputFocused)
                    .onSubmit(send)

                Button {
                    // Construct the recognizer lazily; ask permission on first mic use only.
                    let recognizer = speech ?? SpeechRecognizer()
                    if speech == nil { speech = recognizer }
                    Task {
                        await recognizer.requestAuthorization()
                        withAnimation { recognizer.toggle() }
                    }
                } label: {
                    Image(systemName: isListening ? "stop.fill" : "mic.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(isListening ? Color.red : Theme.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isListening ? "Stop dictation" : "Dictate")

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(canSend ? Theme.accent : Color.secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
        .onChange(of: speech?.transcript) { _, text in
            if let text, !text.isEmpty { input = text }
        }
        .onChange(of: speech?.state) { old, new in
            // When dictation finishes with text in the box, send it automatically.
            if old == .listening, new == .idle,
               !input.trimmingCharacters(in: .whitespaces).isEmpty {
                send()
            }
        }
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isThinking
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isThinking else { return }
        speech?.stop()
        input = ""
        isThinking = true

        Task {
            let draft = await IntentAssistant.draft(from: text)
            // Feedback is the new row itself appearing in the list;
            // reverting it is the toolbar's global Undo (↺), like any other change.
            if !draft.entry.title.isEmpty {
                let item = draft.entry.makeItem()
                item.list = currentList   // capture into the open list, if any
                // ...and assign it to that list's owner, same as the add form and the
                // assistant router do. Without this, items captured inside someone's
                // list land unassigned and vanish from their queue.
                if let owner = currentList?.derivedAssignee { item.assignedTo = owner }
                context.insert(item)
            }
            withAnimation { isThinking = false }
        }
    }

    private var emptyState: some View {
        Group {
            if isSearching {
                ContentUnavailableView {
                    Label("No matches", systemImage: "magnifyingglass")
                } description: {
                    Text("Nothing active matches “\(searchText)”. Archived items aren't searched.")
                }
            } else {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: "sparkles")
                } description: {
                    Text(mode == .task
                         ? "Tap + to add a to-do, or tell the assistant below what you need to do."
                         : "Tap + to add an appointment, or tell the assistant below — e.g. “Lunch with Sam tomorrow 1pm”.")
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyTitle: String {
        if let list = currentList { return "No \(modeTitle.lowercased()) in “\(list.name)”" }
        if case .category(let c) = filter, c != .all { return "Nothing in \(c.title)" }
        return mode == .task ? "No to-dos yet" : "No appointments yet"
    }

    // MARK: - List management

    private func delete(_ source: [PlannerItem], at offsets: IndexSet) {
        for index in offsets { context.delete(source[index]) }
    }
}

#Preview {
    TodoListView()
        .modelContainer(for: PlannerItem.self, inMemory: true)
}
