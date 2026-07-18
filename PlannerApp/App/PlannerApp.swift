import SwiftUI
import SwiftData
import UserNotifications
#if DEBUG
import CoreData
#endif

@main
struct PlannerApp: App {

    /// Re-arm the advance reminders whenever the app comes back to the foreground, so
    /// edits made on another device (via iCloud) are reflected in the pending alerts.
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        Self.initializeCloudKitSchemaIfRequested()
        #endif
    }

    /// SwiftData container backed by the user's **private iCloud** database. With the iCloud
    /// entitlement present, SwiftData mirrors every change to CloudKit automatically, so the
    /// data syncs across all of the user's signed-in devices. If iCloud is unavailable the app
    /// falls back to a purely local store so it still works offline.
    let container: ModelContainer = {
        let schema = Schema([PlannerItem.self, PlannerList.self])
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
                .modelUndoSupport()
                .task { seedSampleDataIfRequested() }
                .task {
                    // Ask once, then arm the advance alerts for everything already due.
                    await ReminderScheduler.requestAuthorization()
                    await ReminderScheduler.rescheduleAll(context: container.mainContext)
                    #if DEBUG
                    await dumpPendingRemindersIfRequested()
                    #endif
                }
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await ReminderScheduler.rescheduleAll(context: container.mainContext) }
        }
    }

    #if DEBUG
    /// DEBUG-only: create/update the CloudKit **development** schema for the SwiftData models.
    /// SwiftData has no schema-init API, so this mirrors the models through
    /// `NSPersistentCloudKitContainer.initializeCloudKitSchema`. Run once on a simulator with
    /// `-initCloudKitSchema`, then deploy Development -> Production in the CloudKit console —
    /// App Store builds sync against Production and fail silently without it.
    private static func initializeCloudKitSchemaIfRequested() {
        guard CommandLine.arguments.contains("-initCloudKitSchema") else { return }
        guard let mom = NSManagedObjectModel.makeManagedObjectModel(for: [PlannerItem.self, PlannerList.self]) else {
            report("CK-SCHEMA: failed to build managed object model")
            return
        }
        let desc = NSPersistentStoreDescription(
            url: URL.temporaryDirectory.appending(path: "ck-schema-init.sqlite"))
        desc.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
            containerIdentifier: "iCloud.com.tertiaryinfotech.plannerapp")
        let container = NSPersistentCloudKitContainer(name: "PlannerApp", managedObjectModel: mom)
        container.persistentStoreDescriptions = [desc]
        container.loadPersistentStores { _, error in
            if let error { report("CK-SCHEMA: store load error: \(error)") }
        }
        do {
            try container.initializeCloudKitSchema(options: [])
            report("CK-SCHEMA: SUCCESS — development schema initialized")
        } catch {
            report("CK-SCHEMA: FAILED — \(error)")
        }
    }

    /// DEBUG-only: print AND persist the schema-init outcome to Documents so headless test
    /// runs (simctl) can read the result from the app container.
    private static func report(_ message: String) {
        print(message)
        let url = URL.documentsDirectory.appending(path: "ck-schema-result.txt")
        try? message.write(to: url, atomically: true, encoding: .utf8)
    }
    #endif

    #if DEBUG
    /// DEBUG-only: write the pending reminder requests to Documents so a headless simulator
    /// run can verify that the advance alerts were actually scheduled. `-dumpReminders`.
    private func dumpPendingRemindersIfRequested() async {
        guard CommandLine.arguments.contains("-dumpReminders") else { return }
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        let df = ISO8601DateFormatter()
        var lines = ["pending=\(pending.count)"]
        for r in pending.sorted(by: { $0.identifier < $1.identifier }) {
            var when = "?"
            if let t = r.trigger as? UNCalendarNotificationTrigger,
               let next = t.nextTriggerDate() {
                when = df.string(from: next)
            }
            lines.append("\(r.identifier) | fires=\(when) | \(r.content.title) | \(r.content.body)")
        }
        let text = lines.joined(separator: "\n")
        print(text)
        let url = URL.documentsDirectory.appending(path: "pending-reminders.txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
    #endif

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
            // Far enough out to sit beyond the reminder lead window, so the advance
            // alerts have something to schedule in demo/screenshot runs.
            PlannerItem(title: "Quarterly review", kind: .appointment, date: at(11, 0, addDays: 14)),
            PlannerItem(title: "Buy groceries", kind: .task),
            PlannerItem(title: "Renew gym membership", kind: .task),
            PlannerItem(title: "Reply to client email", kind: .task)
        ]
        items.forEach { ctx.insert($0) }

        // A small nested list tree so the collapse/expand controls have something to act on.
        if ((try? ctx.fetch(FetchDescriptor<PlannerList>())) ?? []).isEmpty {
            let clients = PlannerList(name: "Clients")
            ctx.insert(clients)
            for name in ["Bizchamp", "Skills Union", "Innohat"] {
                ctx.insert(PlannerList(name: name, parent: clients))
            }
            let projects = PlannerList(name: "Projects")
            ctx.insert(projects)
            ctx.insert(PlannerList(name: "AI-MMS", parent: projects))
        }
        try? ctx.save()
        #endif
    }
}
