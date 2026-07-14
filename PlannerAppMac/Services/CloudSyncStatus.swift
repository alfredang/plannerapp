import Foundation
import CloudKit

/// Live iCloud sync status for the sidebar indicator.
///
/// Sync is "on" when BOTH are true: the SwiftData container came up with its CloudKit
/// mirror (see `PlannerMacApp` — it silently falls back to a local-only store), and the
/// user is signed into iCloud. Re-checks whenever the system posts an account change.
@MainActor
final class CloudSyncStatus: ObservableObject {
    static let shared = CloudSyncStatus()

    /// Set by `PlannerMacApp` right after the ModelContainer is created.
    @Published var containerUsesCloudKit = false
    @Published var accountStatus: CKAccountStatus = .couldNotDetermine

    var isOn: Bool { containerUsesCloudKit && accountStatus == .available }

    var label: String { isOn ? "iCloud Sync On" : "iCloud Sync Off" }

    var detail: String {
        if !containerUsesCloudKit { return "Using a local store — items stay on this Mac." }
        switch accountStatus {
        case .available:            return "Items sync with your other devices through iCloud."
        case .noAccount:            return "Sign into iCloud in System Settings to sync."
        case .restricted:           return "iCloud is restricted on this Mac."
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
    }

    func refresh() {
        CKContainer(identifier: "iCloud.com.tertiaryinfotech.plannerapp")
            .accountStatus { status, _ in
                Task { @MainActor in self.accountStatus = status }
            }
    }
}
