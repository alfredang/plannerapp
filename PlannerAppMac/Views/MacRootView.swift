import SwiftUI
import SwiftData

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

    // Active items, for the sidebar badge counts.
    @Query(filter: #Predicate<PlannerItem> { !$0.isArchived })
    private var activeItems: [PlannerItem]

    @Query(filter: #Predicate<PlannerItem> { $0.isArchived })
    private var archivedItems: [PlannerItem]

    @Query(sort: \PlannerList.createdAt)
    private var lists: [PlannerList]

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .onChange(of: lists.count) {
            // If the selected user list was deleted (locally or via sync), fall back to All.
            if case .userList(let id) = selection, !lists.contains(where: { $0.id == id }) {
                selection = .category(.all)
            }
        }
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
                ForEach(lists) { list in
                    userListRow(list)
                }
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

#Preview {
    MacRootView()
        .modelContainer(for: PlannerItem.self, inMemory: true)
}
