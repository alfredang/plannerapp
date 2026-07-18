import Foundation
import SwiftData

/// Finds items that look accidentally duplicated, so they can be reviewed before they clutter
/// a calendar or fire two reminders for the same thing.
///
/// The rule is deliberately conservative: a duplicate is **the same title on the same day**.
/// Two sessions of a multi-day course ("LHUB n8n Training" on the 30th and the 31st) share a
/// title but not a day, and are NOT duplicates — flagging those would invite deleting a real
/// training day.
enum DuplicateAudit {

    /// One cluster of items judged to be duplicates of each other.
    struct Group: Identifiable {
        let id = UUID()
        /// The item to keep — the earliest-created, so the original survives.
        let keep: PlannerItem
        /// The later copies, offered for archiving.
        let extras: [PlannerItem]

        var title: String { keep.title }
        var count: Int { extras.count + 1 }

        /// "3 Aug" for dated items, "no date" otherwise — shown so the user can see *why*
        /// these were grouped.
        var dayLabel: String {
            guard let d = keep.date else { return "no date" }
            return d.formatted(.dateTime.day().month())
        }
    }

    /// Duplicate clusters among active items, newest copies listed for archiving.
    ///
    /// - Parameter kind: restrict to one kind, or `nil` to audit everything.
    static func findDuplicates(in items: [PlannerItem], kind: PlannerKind? = nil) -> [Group] {
        let candidates = items.filter { item in
            !item.isArchived && (kind == nil || item.kind == kind)
        }

        // Key on normalised title + calendar day. Undated items group by title alone.
        var buckets: [String: [PlannerItem]] = [:]
        for item in candidates {
            let title = item.title
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !title.isEmpty else { continue }
            let day: String
            if let date = item.date {
                let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
                day = "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
            } else {
                day = "nodate"
            }
            buckets["\(title)|\(day)", default: []].append(item)
        }

        return buckets.values
            .filter { $0.count > 1 }
            .map { group in
                // Keep the original: earliest createdAt.
                let ordered = group.sorted { $0.createdAt < $1.createdAt }
                return Group(keep: ordered[0], extras: Array(ordered.dropFirst()))
            }
            .sorted { $0.title < $1.title }
    }

    /// Archive the redundant copies in a group. Archiving (never deleting) keeps them
    /// recoverable — the same rule the assistant follows.
    static func resolve(_ group: Group) {
        for extra in group.extras where !extra.isArchived {
            extra.isArchived = true
            extra.completedAt = Date()
        }
    }
}
