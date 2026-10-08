import SwiftUI
import SwiftData
#if DEBUG
import CoreData
#endif

@main
struct PlannerMacApp: App {

    /// Mirrors the terminal panel visibility used by `MacRootView`, so the View-menu
    /// command below and the toolbar button stay in sync via UserDefaults.
    @AppStorage("hermesPanelVisible") private var hermesVisible = true

    /// Applies the saved Light/Dark/System default before the first window draws.
    @NSApplicationDelegateAdaptor(PlannerMacAppDelegate.self) private var appDelegate

    init() {
        #if DEBUG
        Self.initializeCloudKitSchemaIfRequested()
        #endif
    }

    /// Same SwiftData schema and iCloud container as the iOS app, so items and lists sync
    /// across the user's devices through their private CloudKit database. The entitlements
    /// pin `icloud-container-environment` to Production so this build talks to the SAME
    /// environment as the App Store iPhone app. If iCloud is unavailable (signed out, or a
    /// build without the entitlement) the app falls back to a purely local store.
    let container: ModelContainer = {
        let schema = Schema([PlannerItem.self, PlannerList.self])
        #if DEBUG
        // A schema-init run must never open the real store: this build talks to the
        // Development environment, and mirroring the live data there would muddle it.
        if CommandLine.arguments.contains("-initCloudKitSchema") {
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true,
                                            cloudKitDatabase: .none)
            // swiftlint:disable:next force_try
            return try! ModelContainer(for: schema, configurations: memory)
        }
        #endif
        do {
            let config = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .automatic
            )
            let container = try ModelContainer(for: schema, configurations: config)
            Task { @MainActor in CloudSyncStatus.shared.containerUsesCloudKit = true }
            return container
        } catch {
            // Fall back to a local-only store so the app never fails to launch.
            let local = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
            do {
                return try ModelContainer(for: schema, configurations: local)
            } catch {
                let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                // swiftlint:disable:next force_try
                return try! ModelContainer(for: schema, configurations: memory)
            }
        }
    }()

    #if DEBUG
    /// DEBUG-only: create/update the CloudKit **development** schema for the SwiftData models
    /// (same helper as the iOS app). Run a Debug build with `-initCloudKitSchema` — the build
    /// must NOT pin `icloud-container-environment` to Production (schema init is a
    /// Development-environment operation), and the Mac must be signed into iCloud. Then deploy
    /// Development → Production in the CloudKit console.
    private static func initializeCloudKitSchemaIfRequested() {
        guard CommandLine.arguments.contains("-initCloudKitSchema") else { return }
        guard let mom = NSManagedObjectModel.makeManagedObjectModel(for: [PlannerItem.self, PlannerList.self]) else {
            print("CK-SCHEMA: failed to build managed object model")
            return
        }
        let desc = NSPersistentStoreDescription(
            url: URL.temporaryDirectory.appending(path: "ck-schema-init.sqlite"))
        desc.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
            containerIdentifier: "iCloud.com.tertiaryinfotech.plannerapp")
        let container = NSPersistentCloudKitContainer(name: "PlannerApp", managedObjectModel: mom)
        container.persistentStoreDescriptions = [desc]
        container.loadPersistentStores { _, error in
            if let error { print("CK-SCHEMA: store load error: \(error)") }
        }
        do {
            try container.initializeCloudKitSchema(options: [])
            print("CK-SCHEMA: SUCCESS — development schema initialized")
        } catch {
            print("CK-SCHEMA: FAILED — \(error)")
        }
        // Done: don't go on to launch the app UI for a schema-init run.
        exit(0)
    }
    #endif

    var body: some Scene {
        WindowGroup {
            MacRootView()
                .tint(Theme.accent)
                .modelUndoSupport()
                .frame(minWidth: 860, minHeight: 560)
                // Route planner:// URL events (the Hermes bridge) into THIS window.
                // Without this, every external URL spawns a brand-new window.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .modelContainer(container)
        .handlesExternalEvents(matching: ["*"])
        .defaultSize(width: 1080, height: 700)
        .commands {
            SidebarCommands()   // View > Toggle Sidebar
            CommandGroup(after: .sidebar) {
                Button(hermesVisible ? "Hide Hermes Terminal" : "Show Hermes Terminal") {
                    hermesVisible.toggle()
                }
                .keyboardShortcut("t", modifiers: [.command, .option])
                Button("Toggle Light / Dark Mode") {
                    AppearanceController.shared.toggle()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }

        Settings {
            MacSettingsPane()
                .frame(width: 480)
                // The Settings scene is separate from the WindowGroup, so it needs the
                // container too — without it any @Query here silently returns nothing.
                .modelContainer(container)
        }
    }
}

/// Sets the app-wide appearance from the saved default as early as possible, so the first
/// window opens already in the right mode instead of flashing the system one.
final class PlannerMacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppearanceController.shared.apply() }
        // Before the terminal panel starts Hermes, so its `-s planner-app` skill exists.
        HermesBridge.prepareWorkspace()
    }
}
