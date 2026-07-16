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
                        ForEach(ListHierarchy.rows(lists)) { row in
                            HStack {
                                Label(row.list.name, systemImage: "folder")
                                    .padding(.leading, CGFloat(row.depth) * 20)
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
                            .contentShape(Rectangle())
                            .onTapGesture { beginRename(row.list) }
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
        newParent = nil
    }

    private func delete(at offsets: IndexSet) {
        let rows = ListHierarchy.rows(lists)
        for index in offsets { context.delete(rows[index].list) }
    }

    /// Drag over the flattened outline: reorders siblings, and dropping into a group's
    /// children nests the dragged list there (see ListHierarchy.applyMove).
    private func move(from source: IndexSet, to destination: Int) {
        ListHierarchy.applyMove(ListHierarchy.rows(lists), from: source, to: destination)
    }
}

#Preview {
    ListsManagerView()
        .modelContainer(for: PlannerItem.self, inMemory: true)
}
