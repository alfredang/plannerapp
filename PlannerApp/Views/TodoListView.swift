import SwiftUI
import SwiftData

/// The main planner screen: every active (non-archived) to-do and appointment, grouped by kind.
/// Includes the **voice add** mic button and a manual add button.
struct TodoListView: View {
    @Environment(\.modelContext) private var context

    // Active items only; checked items auto-archive and disappear from here.
    @Query(
        filter: #Predicate<PlannerItem> { !$0.isArchived },
        sort: [SortDescriptor(\PlannerItem.date), SortDescriptor(\PlannerItem.createdAt, order: .reverse)]
    )
    private var items: [PlannerItem]

    @Query(sort: \PlannerList.createdAt) private var lists: [PlannerList]

    @State private var showingAdd = false
    @State private var showingVoice = false
    @State private var showingLists = false
    @State private var editingItem: PlannerItem?
    @State private var selectedListID: UUID?

    private var selectedList: PlannerList? { lists.first { $0.id == selectedListID } }

    /// Items in the currently selected list (or every active item when no list is selected).
    private var visibleItems: [PlannerItem] {
        guard let selectedListID else { return items }
        return items.filter { $0.list?.id == selectedListID }
    }

    private var tasks: [PlannerItem] { visibleItems.filter { $0.kind == .task } }
    private var appointments: [PlannerItem] { visibleItems.filter { $0.kind == .appointment } }

    var body: some View {
        NavigationStack {
            Group {
                if visibleItems.isEmpty {
                    emptyState
                } else {
                    List {
                        if !appointments.isEmpty {
                            Section("Appointments") {
                                ForEach(appointments) { row($0) }
                                    .onDelete { delete(appointments, at: $0) }
                            }
                        }
                        if !tasks.isEmpty {
                            Section("To-Do") {
                                ForEach(tasks) { row($0) }
                                    .onDelete { delete(tasks, at: $0) }
                            }
                        }
                    }
                }
            }
            .navigationTitle(selectedList?.name ?? "Planner")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { listMenu }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAdd = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add item")
                }
            }
            .safeAreaInset(edge: .bottom) { voiceButton }
            .sheet(isPresented: $showingAdd) { AddItemView(defaultList: selectedList) }
            .sheet(isPresented: $showingVoice) { VoiceCaptureView() }
            .sheet(isPresented: $showingLists) { ListsManagerView() }
            .sheet(item: $editingItem) { AddItemView(item: $0) }
            .onChange(of: lists.count) {
                // If the selected list was deleted, fall back to all items.
                if selectedListID != nil && selectedList == nil { selectedListID = nil }
            }
        }
    }

    /// Switch between "all items" and a specific user list, and manage the lists themselves.
    private var listMenu: some View {
        Menu {
            Picker("List", selection: $selectedListID) {
                Label("All Items", systemImage: "tray.full").tag(UUID?.none)
                ForEach(lists) { list in
                    Label(list.name, systemImage: "folder").tag(Optional(list.id))
                }
            }
            Divider()
            Button {
                showingLists = true
            } label: {
                Label("Manage Lists…", systemImage: "folder.badge.gearshape")
            }
        } label: {
            Image(systemName: selectedListID == nil
                  ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityLabel("Choose list")
    }

    private func row(_ item: PlannerItem) -> some View {
        ItemRow(item: item) {
            withAnimation { item.toggleDone() }   // checking auto-archives
        } onEdit: {
            editingItem = item
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
            Label(selectedList == nil ? "Nothing planned yet" : "“\(selectedList!.name)” is empty",
                  systemImage: "sparkles")
        } description: {
            Text("Tap + to add a to-do or appointment, or use the mic to add one by voice.")
        }
    }

    private func delete(_ source: [PlannerItem], at offsets: IndexSet) {
        for index in offsets { context.delete(source[index]) }
    }
}

#Preview {
    TodoListView()
        .modelContainer(for: PlannerItem.self, inMemory: true)
}
