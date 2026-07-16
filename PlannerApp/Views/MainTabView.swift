import SwiftUI

/// Root navigation. House-style bottom tabs: the app's content first, then Feedback + About.
struct MainTabView: View {
    private enum Tab: Hashable {
        case assistant, appointments, todos, calendar, archive, feedback, about
    }

    @State private var selection: Tab = .appointments

    init() {
        #if DEBUG
        // Screenshot/test helper: `-openPlanner` (etc.) jumps straight to a tab at launch.
        if CommandLine.arguments.contains("-openPlanner") {
            _selection = State(initialValue: .todos)
        } else if CommandLine.arguments.contains("-openCalendar") {
            _selection = State(initialValue: .calendar)
        }
        #endif
    }

    var body: some View {
        TabView(selection: $selection) {
            // Appointments and To-Dos are separate tabs — never both on one page.
            // Each keeps the list chips and the bottom chatbot capture bar.
            TodoListView(mode: .appointment)
                .tabItem { Label("Appointments", systemImage: "calendar") }
                .tag(Tab.appointments)

            TodoListView(mode: .task)
                .tabItem { Label("To-Dos", systemImage: "checklist") }
                .tag(Tab.todos)

            AssistantChatView()
                .tabItem { Label("Chat", systemImage: "sparkles") }
                .tag(Tab.assistant)

            CalendarView()
                .tabItem { Label("Calendar", systemImage: "calendar") }
                .tag(Tab.calendar)

            ArchiveView()
                .tabItem { Label("Archive", systemImage: "archivebox.fill") }
                .tag(Tab.archive)

            FeedbackView()
                .tabItem { Label("Feedback", systemImage: "bubble.left.and.bubble.right.fill") }
                .tag(Tab.feedback)

            AboutView()
                .tabItem { Label("About", systemImage: "info.circle.fill") }
                .tag(Tab.about)
        }
        .tint(Theme.accent)
    }
}

#Preview {
    MainTabView()
        .modelContainer(for: PlannerItem.self, inMemory: true)
}
