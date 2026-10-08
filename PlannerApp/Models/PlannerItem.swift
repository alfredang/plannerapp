import Foundation
import SwiftData
import CoreTransferable
import UniformTypeIdentifiers

/// The kind of entry. Backed by a raw `String` so it stays CloudKit-compatible.
enum PlannerKind: String, CaseIterable, Identifiable {
    case task
    case appointment

    var id: String { rawValue }
    var title: String { self == .task ? "To-Do" : "Appointment" }
    var symbol: String { self == .task ? "checklist" : "calendar" }
}

/// How urgent a to-do is. Persisted as an Int (CloudKit-friendly); higher = more urgent.
/// Critical and High to-dos are pinned automatically (see `PlannerItem.setPriority`).
enum PlannerPriority: Int, CaseIterable, Identifiable, Comparable {
    case low = 0, medium = 1, high = 2, critical = 3

    var id: Int { rawValue }

    /// Menu / picker order, most urgent first.
    static let ordered: [PlannerPriority] = [.critical, .high, .medium, .low]

    var title: String {
        switch self {
        case .critical: return "Critical"
        case .high:     return "High"
        case .medium:   return "Medium"
        case .low:      return "Low"
        }
    }

    var symbol: String {
        switch self {
        case .critical: return "exclamationmark.3"
        case .high:     return "exclamationmark.2"
        case .medium:   return "minus"
        case .low:      return "arrow.down"
        }
    }

    /// Critical and High to-dos float to the top as pinned.
    var autoPins: Bool { self >= .high }

    /// Parses "critical" / "high" / "medium" / "low" (and a few shorthands) for the agent bridge.
    init?(name: String) {
        switch name.lowercased().trimmingCharacters(in: .whitespaces) {
        case "critical", "crit", "urgent", "p0": self = .critical
        case "high", "hi", "p1":                 self = .high
        case "medium", "med", "normal", "p2":    self = .medium
        case "low", "lo", "p3":                  self = .low
        default: return nil
        }
    }

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// A single entry in the planner — either a to-do task or a calendar appointment.
///
/// CloudKit requirements honoured here: every stored property has a default value (or is
/// optional), there are no unique constraints, and there are no required relationships. This
/// lets SwiftData mirror the store to the user's private iCloud database automatically.
@Model
final class PlannerItem {
    var id: UUID = UUID()
    var title: String = ""
    var notes: String = ""

    /// `PlannerKind` raw value — "task" or "appointment".
    var kindRaw: String = PlannerKind.task.rawValue

    /// When the appointment occurs. `nil` for plain tasks (and optional tasks with no due time).
    var date: Date?

    /// Checked-off state. Checking an item triggers auto-archive (see `markDone`).
    var isDone: Bool = false
    var isArchived: Bool = false

    /// The user list this item belongs to, if any. Optional (CloudKit requirement); the
    /// inverse relationship is declared on `PlannerList.items`.
    var list: PlannerList?

    var createdAt: Date = Date()
    var completedAt: Date?

    /// Manual drag-rearrange position, synced via CloudKit so Mac and iOS agree. 0 (the
    /// legacy default) means "never manually placed" — such rows keep the date sort among
    /// themselves. Reordering a view writes 1-based positions for every visible row.
    var sortOrder: Int = 0

    /// Pinned rows float above the rest of their section (synced via CloudKit).
    var isPinned: Bool = false

    /// Who this item is assigned to (free text, e.g. an intern's name). Empty = unassigned.
    var assignedTo: String = ""

    /// To-do priority (`PlannerPriority` raw value), synced via CloudKit. Defaults to
    /// Medium, so items from before priorities existed read as normal.
    var priorityRaw: Int = PlannerPriority.medium.rawValue

    /// Identifier of the mirrored event in the system Calendar (see `CalendarSync`), so an
    /// edit updates that event instead of creating a duplicate. Optional (CloudKit
    /// requirement); `nil` until the appointment has been mirrored.
    var calendarEventID: String?

    init(
        title: String,
        notes: String = "",
        kind: PlannerKind = .task,
        date: Date? = nil
    ) {
        self.id = UUID()
        self.title = title
        self.notes = notes
        self.kindRaw = kind.rawValue
        self.date = date
        self.isDone = false
        self.isArchived = false
        self.createdAt = Date()
        self.completedAt = nil
    }

    var kind: PlannerKind {
        get { PlannerKind(rawValue: kindRaw) ?? .task }
        set { kindRaw = newValue.rawValue }
    }

    var isAppointment: Bool { kind == .appointment }

    var priority: PlannerPriority {
        get { PlannerPriority(rawValue: priorityRaw) ?? .medium }
        set { priorityRaw = newValue.rawValue }
    }

    /// Change the priority, keeping the pin in step: Critical and High pin the to-do, and
    /// lowering it from there to Medium or Low unpins it again. A manual pin on a Medium or
    /// Low to-do is left alone.
    func setPriority(_ newValue: PlannerPriority) {
        let wasAutoPinned = priority.autoPins
        priority = newValue
        if newValue.autoPins {
            isPinned = true
        } else if wasAutoPinned {
            isPinned = false
        }
    }

    /// True when this item belongs in the owner's own queue: either nobody is assigned, or
    /// it is assigned to the owner themselves. Work delegated to someone else is excluded,
    /// so the smart views (All / Pinned / Today) stay the owner's personal list.
    /// Matching is case- and whitespace-insensitive so "alfred" and "Alfred " both count.
    func isMine(ownerName: String) -> Bool {
        let assignee = assignedTo.trimmingCharacters(in: .whitespacesAndNewlines)
        if assignee.isEmpty { return true }
        let owner = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !owner.isEmpty else { return false }
        return assignee.caseInsensitiveCompare(owner) == .orderedSame
    }

    /// Whether this item matches a search query. Every whitespace-separated word must appear
    /// somewhere in the title, notes, assignee or list name, so "ryan n8n" finds Ryan's n8n
    /// task regardless of word order. An empty query matches everything.
    func matches(_ query: String) -> Bool {
        let terms = query.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !terms.isEmpty else { return true }
        let haystack = [title, notes, assignedTo, list?.name ?? ""]
            .joined(separator: " ")
            .lowercased()
        return terms.allSatisfy { haystack.contains($0) }
    }

    /// Toggle completion. Checking an item auto-archives it (per app spec); unchecking restores it.
    func toggleDone() {
        isDone.toggle()
        if isDone {
            completedAt = Date()
            isArchived = true          // auto-archive on check
        } else {
            completedAt = nil
            isArchived = false         // restore when unchecked from the archive
        }
    }
}

/// The payload for dragging a planner item onto a sidebar list.
///
/// Only the item's `id` travels — the receiving side re-fetches the live `PlannerItem`,
/// since SwiftData objects can't cross a drag boundary. Lives here rather than in its
/// own file so it's picked up by both app targets' existing source lists.
///
/// This is an `NSItemProvider`-based payload rather than a `Transferable` struct because
/// SwiftUI's `.draggable` is swallowed by `List(selection:)`, whose rows are already
/// drag sources for selection. `.onDrag` sits below that gesture layer and works.
@objc(PlannerItemDragPayload)
final class PlannerItemDragPayload: NSObject, NSItemProviderWriting, NSItemProviderReading {
    let id: UUID

    init(id: UUID) { self.id = id }

    static var writableTypeIdentifiersForItemProvider: [String] { [UTType.plannerItem.identifier] }
    static var readableTypeIdentifiersForItemProvider: [String] { [UTType.plannerItem.identifier] }

    func loadData(withTypeIdentifier typeIdentifier: String,
                  forItemProviderCompletionHandler completionHandler:
                    @escaping @Sendable (Data?, Error?) -> Void) -> Progress? {
        completionHandler(Data(id.uuidString.utf8), nil)
        return nil
    }

    static func object(withItemProviderData data: Data,
                       typeIdentifier: String) throws -> Self {
        guard let uuid = UUID(uuidString: String(decoding: data, as: UTF8.self)) else {
            throw CocoaError(.formatting)
        }
        return Self(id: uuid)
    }
}

extension UTType {
    /// Private in-process drag type, so planner rows only drop onto our own targets.
    static let plannerItem = UTType(exportedAs: "com.tertiaryinfotech.plannerapp.item")
}
