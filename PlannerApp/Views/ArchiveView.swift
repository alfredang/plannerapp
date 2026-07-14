import SwiftUI
import SwiftData

/// Completed items auto-archive here. Users can restore (uncheck) or delete them.
struct ArchiveView: View {
    @Environment(\.modelContext) private var context

    @Query(
        filter: #Predicate<PlannerItem> { $0.isArchived },
        sort: \PlannerItem.completedAt,
        order: .reverse
    )
    private var archived: [PlannerItem]

    var body: some View {
        NavigationStack {
            Group {
                if archived.isEmpty {
                    ContentUnavailableView(
                        "Archive is empty",
                        systemImage: "archivebox",
                        description: Text("When you check off a to-do or appointment, it’s archived here automatically.")
                    )
                } else {
                    List {
                        ForEach(archived) { item in
                            ItemRow(item: item) {
                                withAnimation { item.toggleDone() }   // unchecking restores to the active list
                            }
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .navigationTitle("Archive")
            .toolbar {
                if !archived.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button(role: .destructive) { clearAll() } label: {
                            Text("Clear")
                        }
                    }
                }
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets { context.delete(archived[index]) }
    }

    private func clearAll() {
        for item in archived { context.delete(item) }
    }
}

#Preview {
    ArchiveView()
        .modelContainer(for: PlannerItem.self, inMemory: true)
}
