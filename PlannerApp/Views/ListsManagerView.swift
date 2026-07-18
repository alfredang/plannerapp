import SwiftUI
import SwiftData

/// Create, rename and delete the user's to-do lists. Cross-platform: presented as a sheet
/// from the Planner tab on iOS and available from the sidebar on macOS. Deleting a list
/// keeps its items — they simply return to "no list".
struct ListsManagerView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \PlannerList.createdAt) private var lists: [PlannerList]

    @State private var showingNew = false
    @State private var newName = ""
    /// When set, the New List alert creates a sub-list under this parent.
    @State private var newParent: PlannerList?
    @State private var renamingList: PlannerList?
    @State private var renameText = ""

    /// Collapsed parent lists, stored locally as comma-joined UUIDs — per-device UI state,
    /// not synced data. Shares the `collapsedLists` key with the Mac sidebar.
    @AppStorage("collapsedLists") private var collapsedListsRaw = ""

    private var collapsedLists: Set<UUID> {
        Set(collapsedListsRaw.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }

    private func toggleCollapsed(_ id: UUID) {
        var set = collapsedLists
        if !set.insert(id).inserted { set.remove(id) }
        collapsedListsRaw = set.map(\.uuidString).joined(separator: ",")
    }

    /// Only lists with sub-lists can collapse.
    private var collapsibleListIDs: [UUID] {
        lists.filter { !($0.children ?? []).isEmpty }.map(\.id)
    }

    /// True when at least one parent list is still expanded (so "Collapse All" has work).
    private var hasExpandedLists: Bool {
        let collapsed = collapsedLists
        return collapsibleListIDs.contains { !collapsed.contains($0) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if lists.isEmpty {
                    ContentUnavailableView {
                        Label("No lists yet", systemImage: "folder.badge.plus")
                    } description: {
                        Text("Create lists like “Work” or “Groceries” to organize your to-dos.")
                    }
                } else {
                    List {
                        ForEach(ListHierarchy.rows(lists, collapsed: collapsedLists)) { row in
                            // Tapping a folder opens it to reveal its to-dos & appointments.
                            // Rename/pin/delete live in the context menu (long-press).
                            NavigationLink {
                                ListDetailView(list: row.list)
                            } label: {
                                HStack(spacing: 6) {
                                    // Chevron only for lists that actually have sub-lists;
                                    // tapping it collapses/expands without opening the folder.
                                    if !(row.list.children ?? []).isEmpty {
                                        let isCollapsed = collapsedLists.contains(row.list.id)
                                        Button {
                                            withAnimation(.easeInOut(duration: 0.15)) {
                                                toggleCollapsed(row.list.id)
                                            }
                                        } label: {
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundStyle(.secondary)
                                                .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                                                .frame(width: 22, height: 30)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel(isCollapsed
                                                            ? "Expand \(row.list.name)"
                                                            : "Collapse \(row.list.name)")
                                    }
                                    Label(row.list.name, systemImage: "folder")
                                    if row.list.isPinned {
                                        Image(systemName: "pin.fill")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.orange)
                                            .accessibilityLabel("Pinned")
                                    }
                                    Spacer()
                                    Text("\(row.list.subtreeActiveCount)")
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                                .padding(.leading, CGFloat(row.depth) * 28)
                            }
                            .contextMenu {
                                Button(row.list.isPinned ? "Unpin" : "Pin to Top") {
                                    withAnimation { row.list.isPinned.toggle() }
                                }
                                Button("New Sub-list…") {
                                    newName = ""
                                    newParent = row.list
                                    showingNew = true
                                }
                                Button("Rename…") { beginRename(row.list) }
                                Button("Delete", role: .destructive) { context.delete(row.list) }
                            }
                        }
                        .onDelete(perform: delete)
                        .onMove(perform: move)
                    }
                }
            }
            .navigationTitle("My Lists")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                #if os(iOS)
                // Shows the reorder grips; long-press-drag also works without it.
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
                #endif
                if !collapsibleListIDs.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                if hasExpandedLists {
                                    collapsedListsRaw = collapsibleListIDs
                                        .map(\.uuidString).joined(separator: ",")
                                } else {
                                    collapsedListsRaw = ""
                                }
                            }
                        } label: {
                            Label(hasExpandedLists ? "Collapse All" : "Expand All",
                                  systemImage: hasExpandedLists
                                  ? "arrow.down.right.and.arrow.up.left"
                                  : "arrow.up.left.and.arrow.down.right")
                        }
                        .accessibilityLabel(hasExpandedLists ? "Collapse all lists" : "Expand all lists")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        newName = ""
                        newParent = nil
                        showingNew = true
                    } label: {
                        Label("New List", systemImage: "plus")
                    }
                    .accessibilityLabel("New list")
                }
            }
            .alert(newParent == nil ? "New List" : "New Sub-list", isPresented: $showingNew) {
                TextField("Name", text: $newName)
                Button("Create") { create() }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let parent = newParent {
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
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 340)
        #endif
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renamingList != nil }, set: { if !$0 { renamingList = nil } })
    }

    private func beginRename(_ list: PlannerList) {
        renameText = list.name
        renamingList = list
    }

    private func commitRename() {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let list = renamingList, !name.isEmpty { list.name = name }
        renamingList = nil
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        context.insert(PlannerList(name: name, parent: newParent))
        // Reveal the new sub-list if its parent was collapsed.
        if let parent = newParent, collapsedLists.contains(parent.id) {
            toggleCollapsed(parent.id)
        }
        newParent = nil
    }

    private func delete(at offsets: IndexSet) {
        // Must match the rows the ForEach renders, or the offsets point at the wrong lists.
        let rows = ListHierarchy.rows(lists, collapsed: collapsedLists)
        for index in offsets { context.delete(rows[index].list) }
    }

    /// Drag over the flattened outline: reorders siblings, and dropping into a group's
    /// children nests the dragged list there (see ListHierarchy.applyMove).
    private func move(from source: IndexSet, to destination: Int) {
        ListHierarchy.applyMove(ListHierarchy.rows(lists, collapsed: collapsedLists),
                                from: source, to: destination)
    }
}

/// The to-dos & appointments inside a folder (and its sub-lists), reached by tapping the
/// folder in Manage Lists. Check items off, tap to edit, or add a new one into this folder.
struct ListDetailView: View {
    @Environment(\.modelContext) private var context
    let list: PlannerList

    @Query(
        filter: #Predicate<PlannerItem> { !$0.isArchived },
        sort: [SortDescriptor(\PlannerItem.date), SortDescriptor(\PlannerItem.createdAt, order: .reverse)]
    )
    private var allItems: [PlannerItem]

    @State private var showingAdd = false
    @State private var editingItem: PlannerItem?

    /// This folder's items plus everything in its sub-lists.
    private var items: [PlannerItem] {
        let ids = list.subtreeIDs
        return allItems.filter { item in
            guard let listID = item.list?.id else { return false }
            return ids.contains(listID)
        }
    }

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView {
                    Label("Nothing here yet", systemImage: "tray")
                } description: {
                    Text("Tap ＋ to add a to-do or appointment to “\(list.name)”.")
                }
            } else {
                List {
                    ForEach(items) { item in
                        ItemRow(item: item) {
                            withAnimation { item.toggleDone() }
                        } onEdit: {
                            editingItem = item
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { context.delete(items[index]) }
                    }
                }
            }
        }
        .navigationTitle(list.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingAdd = true } label: {
                    Label("Add item", systemImage: "plus")
                }
                .accessibilityLabel("Add item")
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddItemView(prefill: ParsedEntry(title: "", kind: .task, date: nil),
                        defaultList: list)
        }
        .sheet(item: $editingItem) { AddItemView(item: $0) }
    }
}

#Preview {
    ListsManagerView()
        .modelContainer(for: PlannerItem.self, inMemory: true)
}
