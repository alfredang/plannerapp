import Foundation
import SwiftData

/// A user-created to-do list (e.g. "Work", "Groceries"). Items may belong to at most one
/// list; deleting a list keeps its items (they fall back to no list).
///
/// CloudKit requirements honoured here (same as `PlannerItem`): every stored property has a
/// default value, there are no unique constraints, and the relationship is optional.
@Model
final class PlannerList {
    var id: UUID = UUID()
    var name: String = ""
    var createdAt: Date = Date()

    /// Manual drag-rearrange position in the sidebar / chip bar, synced via CloudKit so
    /// Mac and iOS agree. 0 (the legacy default) sorts by createdAt among itself.
    var sortOrder: Int = 0

    @Relationship(deleteRule: .nullify, inverse: \PlannerItem.list)
    var items: [PlannerItem]? = []

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
    }

    /// Active (non-archived) item count, for sidebar/list badges.
    var activeCount: Int {
        (items ?? []).filter { !$0.isArchived }.count
    }
}
