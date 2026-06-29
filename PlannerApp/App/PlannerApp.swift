import SwiftUI
import SwiftData

@main
struct PlannerApp: App {

    /// SwiftData container backed by the user's **private iCloud** database. With the iCloud
    /// entitlement present, SwiftData mirrors every change to CloudKit automatically, so the
    /// data syncs across all of the user's signed-in devices. If iCloud is unavailable the app
    /// falls back to a purely local store so it still works offline.
    let container: ModelContainer = {
        let schema = Schema([PlannerItem.self])
        do {
            let config = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .automatic
            )
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            // Fall back to a local-only store so the app never fails to launch.
            let local = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
            // swiftlint:disable:next force_try
            return try! ModelContainer(for: schema, configurations: local)
        }
    }()

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .tint(Theme.accent)
                .task { seedSampleDataIfRequested() }
        }
        .modelContainer(container)
    }

    /// DEBUG-only: seed demo data for App Store screenshots when launched with `-seedSampleData`.
    /// Never compiled into Release/App Store builds.
    private func seedSampleDataIfRequested() {
        #if DEBUG
        guard CommandLine.arguments.contains("-seedSampleData") else { return }
        let ctx = container.mainContext
        let existing = (try? ctx.fetch(FetchDescriptor<PlannerItem>())) ?? []
        guard existing.isEmpty else { return }
        let cal = Calendar.current
        let now = Date()
        func at(_ h: Int, _ m: Int, addDays d: Int = 0) -> Date {
            let base = cal.date(byAdding: .day, value: d, to: now) ?? now
            return cal.date(bySettingHour: h, minute: m, second: 0, of: base) ?? base
        }
        let items: [PlannerItem] = [
            PlannerItem(title: "Lunch with Sam", kind: .appointment, date: at(13, 0)),
            PlannerItem(title: "Team standup", kind: .appointment, date: at(9, 30, addDays: 1)),
            PlannerItem(title: "Dentist appointment", kind: .appointment, date: at(15, 30, addDays: 2)),
            PlannerItem(title: "Buy groceries", kind: .task),
            PlannerItem(title: "Renew gym membership", kind: .task),
            PlannerItem(title: "Reply to client email", kind: .task)
        ]
        items.forEach { ctx.insert($0) }
        try? ctx.save()
        #endif
    }
}
