import Foundation
import CloudKit
import CoreData
import SwiftData

/// Live iCloud sync status, shared by the iPhone Settings screen and the Mac sidebar.
///
/// Sync is "on" when BOTH are true: the SwiftData container came up with its CloudKit
/// mirror (each app sets `containerUsesCloudKit` right after creating the container — both
/// silently fall back to a local-only store), and the user is signed into iCloud.
/// Re-checks whenever the system posts an account change.
///
/// SwiftData mirrors through `NSPersistentCloudKitContainer` under the hood, so its sync
/// activity still posts `eventChangedNotification` — that is how `lastSyncDate` and
/// `lastSyncError` stay current without any access to the private container.
@MainActor
final class CloudSyncStatus: ObservableObject {
    static let shared = CloudSyncStatus()

    /// Set by each app right after the ModelContainer is created.
    @Published var containerUsesCloudKit = false
    @Published var accountStatus: CKAccountStatus = .couldNotDetermine

    /// When the most recent CloudKit import/export finished, and whether it failed.
    @Published var lastSyncDate: Date?
    @Published var lastSyncError: String?

    var isOn: Bool { containerUsesCloudKit && accountStatus == .available }

    var label: String { isOn ? "iCloud Sync On" : "iCloud Sync Off" }

    var detail: String {
        if !containerUsesCloudKit { return "Using a local store — items stay on this device." }
        switch accountStatus {
        case .available:            return "Items sync with your other devices through iCloud."
        case .noAccount:            return "Sign into iCloud in System Settings to sync."
        case .restricted:           return "iCloud is restricted on this device."
        case .temporarilyUnavailable: return "iCloud is temporarily unavailable."
        default:                    return "Checking iCloud status…"
        }
    }

    private init() {
        refresh()
        NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in CloudSyncStatus.shared.refresh() }
        }
        NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil, queue: .main
        ) { note in
            let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event
            // Only finished events carry an outcome; setup/import/export all count as activity.
            guard let event, let ended = event.endDate else { return }
            Task { @MainActor in
                let status = CloudSyncStatus.shared
                status.lastSyncDate = ended
                status.lastSyncError = event.error?.localizedDescription
            }
        }
    }

    func refresh() {
        CKContainer(identifier: "iCloud.com.tertiaryinfotech.plannerapp")
            .accountStatus { status, _ in
                Task { @MainActor in self.accountStatus = status }
            }
    }

    /// Best-effort "sync now". There is no public API to force a CloudKit import, but
    /// saving pending changes triggers an export immediately, and the account-status
    /// round trip re-establishes the connection after network/iCloud hiccups — together
    /// they cover the cases where sync looks stuck.
    func nudge(context: ModelContext) {
        try? context.save()
        refresh()
    }
}
