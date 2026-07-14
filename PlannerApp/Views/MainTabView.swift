import SwiftUI

/// Root navigation. House-style bottom tabs: the app's content first, then Feedback + About.
struct MainTabView: View {
    private enum Tab: Hashable {
        case assistant, planner, calendar, archive, feedback, about
    }

    @State private var selection: Tab = .assistant

    init() {
        #if DEBUG
        // Screenshot/test helper: `-openPlanner` (etc.) jumps straight to a tab at launch.
        if CommandLine.arguments.contains("-openPlanner") {
            _selection = State(initialValue: .planner)
        } else if CommandLine.arguments.contains("-openCalendar") {
            _selection = State(initialValue: .calendar)
        }
        #endif
    }

    var body: some View {
        TabView(selection: $selection) {
            AssistantChatView()
                .tabItem { Label("Assistant", systemImage: "sparkles") }
                .tag(Tab.assistant)

            TodoListView()
                .tabItem { Label("Planner", systemImage: "checklist") }
                .tag(Tab.planner)

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
