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
                        ForEach(lists) { list in
                            HStack {
                                Label(list.name, systemImage: "folder")
                                Spacer()
                                Text("\(list.activeCount)")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { beginRename(list) }
                            .contextMenu {
                                Button("Rename…") { beginRename(list) }
                                Button("Delete", role: .destructive) { context.delete(list) }
                            }
                        }
                        .onDelete(perform: delete)
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
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        newName = ""
                        showingNew = true
                    } label: {
                        Label("New List", systemImage: "plus")
                    }
                    .accessibilityLabel("New list")
                }
            }
            .alert("New List", isPresented: $showingNew) {
                TextField("Name", text: $newName)
                Button("Create") { create() }
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
        context.insert(PlannerList(name: name))
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets { context.delete(lists[index]) }
    }
}

#Preview {
    ListsManagerView()
        .modelContainer(for: PlannerItem.self, inMemory: true)
}
