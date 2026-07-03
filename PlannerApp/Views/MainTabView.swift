import SwiftUI

/// Root navigation. House-style bottom tabs: the app's content first, then Feedback + About.
struct MainTabView: View {
    var body: some View {
        TabView {
            AssistantChatView()
                .tabItem { Label("Assistant", systemImage: "sparkles") }

            TodoListView()
                .tabItem { Label("Planner", systemImage: "checklist") }

            CalendarView()
                .tabItem { Label("Calendar", systemImage: "calendar") }

            ArchiveView()
                .tabItem { Label("Archive", systemImage: "archivebox.fill") }

            FeedbackView()
                .tabItem { Label("Feedback", systemImage: "bubble.left.and.bubble.right.fill") }

            AboutView()
                .tabItem { Label("About", systemImage: "info.circle.fill") }
        }
        .tint(Theme.accent)
    }
}

#Preview {
    MainTabView()
        .modelContainer(for: PlannerItem.self, inMemory: true)
}
