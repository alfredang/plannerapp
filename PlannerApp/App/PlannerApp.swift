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
        }
        .modelContainer(container)
    }
}
