import SwiftUI
import SwiftData

/// Root navigation. House-style bottom tabs: the app's content first, then Feedback + About.
struct MainTabView: View {
    private enum Tab: Hashable {
        case planner, calendar, archive, settings, feedback, about
    }

    @State private var selection: Tab = .planner

    // Settings ▸ Appearance. Changing the accent rebuilds the tab content (`.id`) so every
    // view re-reads `Theme.accent`; the selected tab survives because it lives out here.
    @AppStorage(AccentTheme.storageKey) private var accentRaw = AccentTheme.indigo.rawValue
    @AppStorage(AppearanceChoice.storageKey) private var appearanceRaw = AppearanceChoice.light.rawValue

    @Environment(\.modelContext) private var context

    /// Active dated items — watched so the notification schedule follows every change
    /// (capture bar, edits, iCloud sync from the Mac), not just launch and foreground.
    @Query(filter: #Predicate<PlannerItem> { !$0.isArchived && $0.date != nil })
    private var datedItems: [PlannerItem]

    private var scheduleFingerprint: Int {
        var hasher = Hasher()
        for item in datedItems {
            hasher.combine(item.id)
            hasher.combine(item.date)
            hasher.combine(item.title)
            hasher.combine(item.kindRaw)
            hasher.combine(item.assignedTo)
        }
        return hasher.finalize()
    }

    init() {
        #if DEBUG
        // Screenshot/test helper: `-openPlanner` (etc.) jumps straight to a tab at launch.
        if CommandLine.arguments.contains("-openPlanner") {
            _selection = State(initialValue: .planner)
        } else if CommandLine.arguments.contains("-openCalendar") {
            _selection = State(initialValue: .calendar)
        } else if CommandLine.arguments.contains("-openSettings") || CommandLine.arguments.contains("-openAppearance") {
            _selection = State(initialValue: .settings)
        }
        #endif
    }

    var body: some View {
        TabView(selection: $selection) {
            // One Planner page: To-Do and Appointment are top tabs inside it (each with
            // its own sub-tabs), with the bottom chatbot capture bar underneath.
            TodoListView()
                .tabItem { Label("Planner", systemImage: "checklist") }
                .tag(Tab.planner)

            CalendarView()
                .tabItem { Label("Calendar", systemImage: "calendar") }
                .tag(Tab.calendar)

            ArchiveView()
                .tabItem { Label("Archive", systemImage: "archivebox.fill") }
                .tag(Tab.archive)

            NavigationStack { RemindersSettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(Tab.settings)

            FeedbackView()
                .tabItem { Label("Feedback", systemImage: "bubble.left.and.bubble.right.fill") }
                .tag(Tab.feedback)

            AboutView()
                .tabItem { Label("About", systemImage: "info.circle.fill") }
                .tag(Tab.about)
        }
        .id(accentRaw)
        .tint(Theme.accent)
        .preferredColorScheme((AppearanceChoice(rawValue: appearanceRaw) ?? .light).colorScheme)
        .task(id: scheduleFingerprint) {
            // Debounce: a burst of changes (a sync import) re-arms once, after it settles.
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await ReminderScheduler.rescheduleAll(context: context)
        }
    }
}

#Preview {
    MainTabView()
        .modelContainer(for: PlannerItem.self, inMemory: true)
}
