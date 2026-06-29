import Foundation
import SwiftData

/// The kind of entry. Backed by a raw `String` so it stays CloudKit-compatible.
enum PlannerKind: String, CaseIterable, Identifiable {
    case task
    case appointment

    var id: String { rawValue }
    var title: String { self == .task ? "To-Do" : "Appointment" }
    var symbol: String { self == .task ? "checklist" : "calendar" }
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

    var createdAt: Date = Date()
    var completedAt: Date?

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
