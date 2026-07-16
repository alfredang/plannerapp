import Foundation

/// Shared helpers for the synced drag-rearrange order (`sortOrder` on `PlannerItem` and
/// `PlannerList`). Position 0 means "never manually placed": those rows keep their default
/// (date/creation) order among themselves, after any manually placed rows. Reordering a view
/// writes 1-based positions to every visible row, so the arrangement syncs via CloudKit.
enum ManualOrder {
    /// Stable sort by manual position; 0 ("unplaced") sorts last, preserving the incoming
    /// default order between unplaced rows.
    static func sorted<T>(_ rows: [T], position: (T) -> Int) -> [T] {
        rows.enumerated().sorted { a, b in
            let pa = position(a.element) == 0 ? Int.max : position(a.element)
            let pb = position(b.element) == 0 ? Int.max : position(b.element)
            return pa == pb ? a.offset < b.offset : pa < pb
        }.map(\.element)
    }

    /// Manual sort with pinned rows floated to the front — each partition keeps its own
    /// manual order.
    static func sortedPinnedFirst<T>(_ rows: [T], pinned: (T) -> Bool,
                                     position: (T) -> Int) -> [T] {
        sorted(rows.filter(pinned), position: position)
            + sorted(rows.filter { !pinned($0) }, position: position)
    }

    /// Applies a List `onMove` to the displayed rows and hands every row its new 1-based
    /// position for persisting.
    static func applyMove<T>(_ rows: [T], from source: IndexSet, to destination: Int,
                             assign: (T, Int) -> Void) {
        var reordered = rows
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, row) in reordered.enumerated() {
            assign(row, index + 1)
        }
    }
}
