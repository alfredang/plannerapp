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

    /// Manual drag-rearrange position among its siblings, synced via CloudKit so Mac and
    /// iOS agree. 0 (the legacy default) sorts by createdAt among itself.
    var sortOrder: Int = 0

    /// Pinned lists float above their siblings in the sidebar / chip bar (synced).
    var isPinned: Bool = false

    /// The list this one nests under, if any — sub-lists (e.g. a client under "Clients").
    /// Optional (CloudKit requirement). Deleting a parent keeps the children: they move
    /// back to the top level via the nullify inverse below.
    var parent: PlannerList?

    @Relationship(deleteRule: .nullify, inverse: \PlannerList.parent)
    var children: [PlannerList]? = []

    @Relationship(deleteRule: .nullify, inverse: \PlannerItem.list)
    var items: [PlannerItem]? = []

    init(name: String, parent: PlannerList? = nil) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.parent = parent
    }

    /// Active (non-archived) item count, for sidebar/list badges.
    var activeCount: Int {
        (items ?? []).filter { !$0.isArchived }.count
    }

    /// Active items in this list plus all nested sub-lists — parent badges aggregate.
    var subtreeActiveCount: Int {
        activeCount + (children ?? []).reduce(0) { $0 + $1.subtreeActiveCount }
    }

    /// This list's id plus every nested sub-list's id, for filtering items by a parent list.
    var subtreeIDs: Set<UUID> {
        var ids: Set<UUID> = [id]
        for child in children ?? [] { ids.formUnion(child.subtreeIDs) }
        return ids
    }

    /// The person this list belongs to, used to auto-fill "Assign to" for items added inside
    /// someone's list (e.g. "Ryan Ngau (NUS)" → "Ryan").
    ///
    /// A list names a person when it sits **directly under a top-level group** — "Interns ▸
    /// Ryan Ngau (NUS)" or the top-level "Alfred". Deeper lists are that person's own
    /// sub-folders ("Alfred ▸ WSQ Course Conversion"), so they inherit the owner from their
    /// ancestor rather than deriving a nonsense assignee ("WSQ") from their own name.
    var derivedAssignee: String? {
        // If an ancestor already names a person, this is that person's own sub-folder
        // ("Alfred ▸ WSQ Course Conversion") — inherit them rather than deriving a nonsense
        // assignee ("WSQ") from this list's own name.
        if let inherited = parent?.derivedAssignee { return inherited }

        // Top-level *category* lists ("Clients", "Project", "Interns") are not people. The
        // exception is the owner's own list, which legitimately holds sub-folders.
        let owner = UserDefaults.standard.string(forKey: "ownerName") ?? "Alfred"
        if parent == nil, !(children ?? []).isEmpty,
           name.caseInsensitiveCompare(owner) != .orderedSame {
            return nil
        }

        // Drop a trailing "(NUS)" / "(NYP)" style suffix, keep the first name.
        let withoutSuffix = name.replacingOccurrences(
            of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
        let first = withoutSuffix
            .split(separator: " ", omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first, first.count > 1 else { return nil }
        return first
    }

    /// True when `self` sits anywhere below `other` — used to keep drags/moves cycle-free.
    func isDescendant(of other: PlannerList) -> Bool {
        var node = parent
        while let current = node {
            if current.id == other.id { return true }
            node = current.parent
        }
        return false
    }
}
