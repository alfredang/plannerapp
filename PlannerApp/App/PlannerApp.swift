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
        // Show alerts as banners even while Planner is open (iOS hides them by default).
        UNUserNotificationCenter.current().delegate = ForegroundNotificationPresenter.shared
        #if DEBUG
        Self.initializeCloudKitSchemaIfRequested()
        #endif
    }

    /// SwiftData container backed by the user's **private iCloud** database. With the iCloud
    /// entitlement present, SwiftData mirrors every change to CloudKit automatically, so the
    /// data syncs across all of the user's signed-in devices. If iCloud is unavailable the app
    /// falls back to a purely local store so it still works offline.
    let container: ModelContainer = {
        let schema = Schema([PlannerItem.self, PlannerList.self, AgentReport.self, ReportReply.self])
        do {
            var database: ModelConfiguration.CloudKitDatabase = .automatic
            var demo = false
            #if DEBUG
            if CommandLine.arguments.contains("-seedSampleData") {
                database = .none
                demo = true
            }
            #endif
            let config = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: demo,
                cloudKitDatabase: database
            )
            let container = try ModelContainer(for: schema, configurations: config)
            Task { @MainActor in CloudSyncStatus.shared.containerUsesCloudKit = !demo }
            return container
        } catch {
            // Fall back to a local-only store so the app never fails to launch.
            let local = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
            // swiftlint:disable:next force_try
            return try! ModelContainer(for: schema, configurations: local)
        }
    }()

    var body: some Scene {
        WindowGroup {
            // Tint and Light/Dark come from Settings ▸ Appearance (applied in MainTabView).
            MainTabView()
                .modelUndoSupport()
                .task {
                    seedSampleDataIfRequested()
                    #if DEBUG
                    dumpTodayAlertsIfRequested()
                    #endif
                }
                .task {
                    // One-time repair for items captured inside someone's list before the
                    // capture bar filled in "Assign to" (see AssigneeBackfill).
                    AssigneeBackfill.runOnce(context: container.mainContext)
                }
                .task {
                    #if DEBUG
                    // Screenshot/demo runs must stay free of permission dialogs.
                    if CommandLine.arguments.contains("-seedSampleData") { return }
                    #endif
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
            // Leaving the app: flush pending edits so they're handed to iCloud before iOS
            // suspends us — otherwise a change made just before locking the phone waits
            // until the next launch to reach the Mac.
            if phase == .background { try? container.mainContext.save() }
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
        guard let mom = NSManagedObjectModel.makeManagedObjectModel(for: [PlannerItem.self, PlannerList.self, AgentReport.self, ReportReply.self]) else {
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
        writeDump(text, to: "pending-reminders.txt")
    }

    /// DEBUG-only: write what `TodayAlerts` WOULD schedule (no permission needed), so the
    /// morning summary and per-appointment alerts can be checked headlessly. `-dumpTodayAlerts`.
    @MainActor
    private func dumpTodayAlertsIfRequested() {
        guard CommandLine.arguments.contains("-dumpTodayAlerts") else { return }
        let items = (try? container.mainContext.fetch(FetchDescriptor<PlannerItem>())) ?? []
        let active = items.filter { $0.kind == .appointment && !$0.isArchived && $0.date != nil }
            .sorted { $0.date! < $1.date! }
        let owner = UserDefaults.standard.string(forKey: "ownerName") ?? "Alfred"
        let requests = TodayAlerts.summaryRequests(active, now: Date())
            + TodayAlerts.alertRequests(active, ownerName: owner, now: Date())
        let df = ISO8601DateFormatter()
        df.timeZone = .current
        let lines = requests.map { r -> String in
            let next = (r.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
            return "\(r.identifier) | fires=\(next.map(df.string(from:)) ?? "?") | \(r.content.title) | \(r.content.body.replacingOccurrences(of: "\n", with: " / "))"
        }
        writeDump((["count=\(requests.count)"] + lines).joined(separator: "\n"), to: "today-alerts.txt")
    }

    private func writeDump(_ text: String, to name: String) {
        let url = URL.documentsDirectory.appending(path: name)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
    #endif

    /// DEBUG-only: seed demo data for App Store screenshots when launched with `-seedSampleData`.
    /// Never compiled into Release/App Store builds.
    private func seedSampleDataIfRequested() {
        #if DEBUG
        guard CommandLine.arguments.contains("-seedSampleData") else { return }
        let ctx = container.mainContext
        if ((try? ctx.fetch(FetchDescriptor<AgentReport>())) ?? []).isEmpty {
            for offset in [0, -1, -2] {
                let day = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
                let key = ReportPresentation.dayKey(day)
                let report = AgentReport(file: "\(key)-oracle-updates.html")
                // Legacy title verifies that already-synced pages use the new wording.
                report.title = offset == 0 ? "Morning Updates Today" : "Morning Updates \(key)"
                report.agent = "Oracle"
                report.dateKey = key
                report.summary = "Prepare today's workshop, confirm client meetings, and review the team's priorities."
                report.html = "<html><head><title>\(report.title)</title></head><body style='font-family:-apple-system;padding:20px'><h1>\(report.title)</h1><p>\(report.summary)</p><div class='item'>Confirm the workshop materials before the session.</div></body></html>"
                ctx.insert(report)
            }
            let review = AgentReport(file: "\(ReportPresentation.dayKey())-nova.html")
            review.title = "Weekly Strategy Review"
            review.agent = "Nova"
            review.dateKey = ReportPresentation.dayKey()
            review.summary = "Review the corporate training pipeline and prepare next week's course plan."
            review.html = "<html><body><h1>Weekly Strategy Review</h1><p>\(review.summary)</p></body></html>"
            ctx.insert(review)
            try? ctx.save()
        }
        let existing = (try? ctx.fetch(FetchDescriptor<PlannerItem>())) ?? []
        guard existing.isEmpty else { return }
        let cal = Calendar.current
        let now = Date()
        func at(_ h: Int, _ m: Int, addDays d: Int = 0) -> Date {
            let base = cal.date(byAdding: .day, value: d, to: now) ?? now
            return cal.date(bySettingHour: h, minute: m, second: 0, of: base) ?? base
        }
        let items: [PlannerItem] = [
            // Yesterday and never ticked, so "Did this happen?" + Reply / comment show.
            PlannerItem(title: "Partner check-in", kind: .appointment, date: at(10, 0, addDays: -1)),
            PlannerItem(title: "Lunch with Sam", kind: .appointment, date: at(13, 0)),
            PlannerItem(title: "Client call", notes: "Meeting link: meet.google.com/abc-defg-hij",
                        kind: .appointment, date: at(16, 0)),
            PlannerItem(title: "Team standup", kind: .appointment, date: at(9, 30, addDays: 1)),
            PlannerItem(title: "Dentist", kind: .appointment, date: at(14, 0, addDays: 1)),
            PlannerItem(title: "Python workshop", kind: .appointment, date: at(10, 0, addDays: 2)),
            PlannerItem(title: "Site visit", kind: .appointment, date: at(11, 0, addDays: 4)),
            PlannerItem(title: "Intern interview", kind: .appointment, date: at(15, 0, addDays: 6)),
            // Far enough out to sit beyond the reminder lead window, so the advance
            // alerts have something to schedule in demo/screenshot runs.
            PlannerItem(title: "Quarterly review", kind: .appointment, date: at(11, 0, addDays: 14)),
            PlannerItem(title: "Buy groceries", kind: .task),
            PlannerItem(title: "Renew gym membership", kind: .task),
            PlannerItem(title: "Reply to client email", kind: .task)
        ]
        // A spread of priorities so the To-Do sort and badges show in screenshots.
        let urgent = PlannerItem(title: "Submit tender proposal", kind: .task, date: at(17, 0, addDays: 1))
        urgent.setPriority(.critical)
        let high = PlannerItem(title: "Prepare course slides", kind: .task)
        high.setPriority(.high)
        items.first { $0.title == "Renew gym membership" }?.setPriority(.low)
        (items + [urgent, high]).forEach { ctx.insert($0) }

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

/// Lets the morning summary and appointment alerts appear while the app is in the
/// foreground — otherwise an 8 am summary is silently dropped if Planner happens to be open.
final class ForegroundNotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ForegroundNotificationPresenter()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
