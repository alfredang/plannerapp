import Foundation

/// Shared presentation + drag logic for the nested list tree (Mac sidebar, iOS chip bar
/// and Manage Lists). Lists render as a flattened, indented outline; a single drag both
/// reorders siblings and re-parents:
///
/// - drop between two top-level rows → the list becomes (or stays) top-level there
/// - drop among a group's children (or right before the first child) → it joins that group
/// - drops that would create a cycle keep the old parent and just reorder
enum ListHierarchy {
    struct Row: Identifiable {
        let list: PlannerList
        let depth: Int
        var id: UUID { list.id }
    }

    /// Depth-first flattened outline: top-level lists in manual order, each followed by its
    /// sub-lists (recursively), themselves in manual order. Children of a list in
    /// `collapsed` are omitted (their stored order is untouched — see applyMove).
    static func rows(_ all: [PlannerList], collapsed: Set<UUID> = []) -> [Row] {
        func append(_ lists: [PlannerList], depth: Int, into rows: inout [Row]) {
            for list in ManualOrder.sortedPinnedFirst(lists, pinned: { $0.isPinned },
                                                      position: { $0.sortOrder }) {
                rows.append(Row(list: list, depth: depth))
                if !collapsed.contains(list.id) {
                    append(list.children ?? [], depth: depth + 1, into: &rows)
                }
            }
        }
        var result: [Row] = []
        append(all.filter { $0.parent == nil }, depth: 0, into: &result)
        return result
    }

    /// Applies a List `onMove` over the flattened rows: infers the dragged list's new
    /// parent from its drop neighbours, then renumbers every sibling group to match the
    /// new visual order. Mutates the models directly (SwiftData persists + syncs).
    static func applyMove(_ rows: [Row], from source: IndexSet, to destination: Int) {
        guard let sourceIndex = source.first else { return }
        var flat = rows
        flat.move(fromOffsets: source, toOffset: destination)
        let movedIndex = destination > sourceIndex ? destination - 1 : destination
        let moved = flat[movedIndex].list

        let prev = movedIndex > 0 ? flat[movedIndex - 1] : nil
        let next = movedIndex + 1 < flat.count ? flat[movedIndex + 1] : nil
        var newParent: PlannerList?
        if let prev, prev.depth > 0, prev.list.id != moved.id {
            newParent = prev.list.parent          // slotted in after a sub-list → same group
        } else if let prev, let next, next.depth > 0, next.list.parent?.id == prev.list.id {
            newParent = prev.list                 // dropped right before a group's first child
        }
        if let candidate = newParent,
           candidate.id == moved.id || candidate.isDescendant(of: moved) {
            newParent = moved.parent              // cycle — keep the old parent, just reorder
        }
        moved.parent = newParent

        // Renumber each sibling group by its order of appearance in the new flat list.
        var counters: [UUID?: Int] = [:]
        for row in flat {
            let parentID = (row.list.id == moved.id ? newParent : row.list.parent)?.id
            let position = (counters[parentID] ?? 0) + 1
            counters[parentID] = position
            row.list.sortOrder = position
        }
    }
}
