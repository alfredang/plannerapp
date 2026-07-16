import SwiftUI
import SwiftData

/// The main planner screen, aligned with the Mac desktop layout: the same smart categories
/// (All Items, Today, Scheduled, To-Dos, Appointments) plus the user's own lists, shown as a
/// visible chip bar. Tap a chip to filter; long-press a list chip to rename or delete it;
/// "＋ New List" creates one. Includes the **voice add** mic button and a manual add button.
struct TodoListView: View {
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
    @State private var showingVoice = false
    @State private var showingLists = false
    @State private var showingNewList = false
    @State private var newListName = ""
    /// When set, the New List alert creates a sub-list under this parent.
    @State private var newListParent: PlannerList?
    @State private var renamingList: PlannerList?
    @State private var renameText = ""
    @State private var editingItem: PlannerItem?

    /// The open user list, when the filter is one.
    private var currentList: PlannerList? {
        guard case .list(let id) = filter else { return nil }
        return lists.first { $0.id == id }
    }

    private var navigationTitle: String {
        switch filter {
        case .category(let c): return c == .all ? "Planner" : c.title
        case .list:            return currentList?.name ?? "Planner"
        }
    }

    private var visibleItems: [PlannerItem] {
        switch filter {
        case .category(let c):
            return items.filter { c.contains($0) }
        case .list:
            // A parent list shows its own items plus everything in its sub-lists.
            let ids = currentList?.subtreeIDs ?? []
            return items.filter { item in
                guard let listID = item.list?.id else { return false }
                return ids.contains(listID)
            }
        }
    }

    /// Rows in manual drag order (synced via CloudKit through `sortOrder`, so the Mac app
    /// shows the same arrangement); never-placed rows keep their date order, after the
    /// placed ones. Same for the list chips below.
    private var tasks: [PlannerItem] {
        ManualOrder.sortedPinnedFirst(visibleItems.filter { $0.kind == .task },
                                      pinned: { $0.isPinned }, position: { $0.sortOrder })
    }
    private var appointments: [PlannerItem] {
        ManualOrder.sortedPinnedFirst(visibleItems.filter { $0.kind == .appointment },
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
                chipBar
                Divider()
                if visibleItems.isEmpty {
                    emptyState
                } else {
                    itemList
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
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
            .safeAreaInset(edge: .bottom) { voiceButton }
            .sheet(isPresented: $showingAdd) { AddItemView(defaultList: currentList) }
            .sheet(isPresented: $showingVoice) { VoiceCaptureView() }
            .sheet(isPresented: $showingLists) { ListsManagerView() }
            .sheet(item: $editingItem) { AddItemView(item: $0) }
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
            .onChange(of: lists.count) {
                // If the selected list was deleted (locally or via sync), fall back to All.
                if case .list(let id) = filter, !lists.contains(where: { $0.id == id }) {
                    filter = .category(.all)
                }
            }
        }
    }

    // MARK: - Chip bar (mirrors the Mac sidebar: smart categories, then My Lists)

    private var chipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(PlannerCategory.allCases) { category in
                    chip(title: category.title,
                         symbol: category.symbol,
                         count: items.filter { category.contains($0) }.count,
                         isSelected: filter == .category(category)) {
                        withAnimation { filter = .category(category) }
                    }
                }

                if !lists.isEmpty {
                    Divider().frame(height: 22)
                }

                ForEach(ListHierarchy.rows(lists)) { row in
                    chip(title: row.depth > 0 ? "↳ \(row.list.name)" : row.list.name,
                         symbol: row.list.isPinned ? "pin.fill" : "folder",
                         count: row.list.subtreeActiveCount,
                         isSelected: filter == .list(row.list.id)) {
                        withAnimation { filter = .list(row.list.id) }
                    }
                    .contextMenu {
                        Button(row.list.isPinned ? "Unpin" : "Pin to Top") {
                            withAnimation { row.list.isPinned.toggle() }
                        }
                        Button("New Sub-list…") {
                            newListName = ""
                            newListParent = row.list
                            showingNewList = true
                        }
                        Button("Rename…") {
                            renameText = row.list.name
                            renamingList = row.list
                        }
                        Button("Delete", role: .destructive) {
                            context.delete(row.list)   // items + sub-lists are kept
                        }
                    }
                }

                Button {
                    newListName = ""
                    newListParent = nil
                    showingNewList = true
                } label: {
                    Label("New List", systemImage: "plus")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Theme.card, in: Capsule())
                        .foregroundStyle(Theme.accent)
                }
                .accessibilityLabel("New list")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
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

    // MARK: - Items

    private var itemList: some View {
        List {
            if !appointments.isEmpty {
                let ordered = appointments
                Section("Appointments") {
                    ForEach(ordered) { row($0) }
                        .onDelete { delete(ordered, at: $0) }
                        .onMove { moveItems(ordered, from: $0, to: $1) }
                }
            }
            if !tasks.isEmpty {
                let ordered = tasks
                Section("To-Do") {
                    ForEach(ordered) { row($0) }
                        .onDelete { delete(ordered, at: $0) }
                        .onMove { moveItems(ordered, from: $0, to: $1) }
                }
            }
        }
    }

    private func row(_ item: PlannerItem) -> some View {
        HStack(spacing: 10) {
            ItemRow(item: item) {
                withAnimation { item.toggleDone() }   // checking auto-archives
            } onEdit: {
                editingItem = item
            }
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Pinned")
            }
            // Drag affordance — hold and drag anywhere on the row to rearrange.
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
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
    }

    private var voiceButton: some View {
        Button {
            showingVoice = true
        } label: {
            Label("Add by Voice", systemImage: "mic.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.accent, in: Capsule())
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 6)
        .accessibilityHint("Dictate a task or appointment")
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: "sparkles")
        } description: {
            Text("Tap + to add a to-do or appointment, or use the mic to add one by voice.")
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyTitle: String {
        if let list = currentList { return "“\(list.name)” is empty" }
        if case .category(let c) = filter, c != .all { return "Nothing in \(c.title)" }
        return "Nothing planned yet"
    }

    // MARK: - List management

    private var renameBinding: Binding<Bool> {
        Binding(get: { renamingList != nil }, set: { if !$0 { renamingList = nil } })
    }

    private func createList() {
        let name = newListName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let list = PlannerList(name: name, parent: newListParent)
        context.insert(list)
        newListParent = nil
        withAnimation { filter = .list(list.id) }
    }

    private func commitRename() {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let list = renamingList, !name.isEmpty { list.name = name }
        renamingList = nil
    }

    private func delete(_ source: [PlannerItem], at offsets: IndexSet) {
        for index in offsets { context.delete(source[index]) }
    }
}

#Preview {
    TodoListView()
        .modelContainer(for: PlannerItem.self, inMemory: true)
}
