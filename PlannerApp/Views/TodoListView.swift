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

    @State private var showingAdd = false
    @State private var showingVoice = false

    private var tasks: [PlannerItem] { items.filter { $0.kind == .task } }
    private var appointments: [PlannerItem] { items.filter { $0.kind == .appointment } }

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
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
            .navigationTitle("Planner")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAdd = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add item")
                }
            }
            .safeAreaInset(edge: .bottom) { voiceButton }
            .sheet(isPresented: $showingAdd) { AddItemView() }
            .sheet(isPresented: $showingVoice) { VoiceCaptureView() }
        }
    }

    private func row(_ item: PlannerItem) -> some View {
        ItemRow(item: item) {
            withAnimation { item.toggleDone() }   // checking auto-archives
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
            Label("Nothing planned yet", systemImage: "sparkles")
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
