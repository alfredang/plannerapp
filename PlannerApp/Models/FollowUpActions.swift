import Foundation
import SwiftData

/// Follow-ups use the existing task and notes fields, so older synced app versions can
/// still display the tasks without requiring a new CloudKit record type or property.
enum FollowUpActions {
    private static let reference = try! NSRegularExpression(
        pattern: #"\s*<!-- planner-follow-up-appointment:\s*([0-9A-Fa-f-]{36})\s*-->"#)

    static func appointmentID(in notes: String) -> UUID? {
        guard let match = reference.firstMatch(in: notes, range: NSRange(notes.startIndex..., in: notes)),
              let range = Range(match.range(at: 1), in: notes) else { return nil }
        return UUID(uuidString: String(notes[range]))
    }

    static func displayNotes(_ notes: String) -> String {
        reference.stringByReplacingMatches(in: notes, range: NSRange(notes.startIndex..., in: notes),
                                            withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func notes(_ text: String, preservingReferenceFrom original: String) -> String {
        let plain = displayNotes(text)
        guard let id = appointmentID(in: original) else { return plain }
        return addingReference(to: plain, appointmentID: id)
    }

    private static func addingReference(to notes: String, appointmentID: UUID) -> String {
        notes + "\n\n<!-- planner-follow-up-appointment: \(appointmentID.uuidString) -->"
    }

    enum ValidationError: LocalizedError {
        case emptyTitle, notAppointment
        var errorDescription: String? {
            switch self {
            case .emptyTitle: return "Enter a follow-up task first."
            case .notAppointment: return "Follow-up actions need an appointment."
            }
        }
    }

    @MainActor
    @discardableResult
    static func add(title: String, to appointment: PlannerItem, ownerName: String,
                    context: ModelContext) throws -> PlannerItem {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ValidationError.emptyTitle }
        guard appointment.isAppointment else { throw ValidationError.notAppointment }
        var origin = "Follow-up from: \(appointment.title)"
        if let date = appointment.date {
            origin += "\nAppointment: \(date.formatted(date: .abbreviated, time: .shortened))"
        }
        let task = PlannerItem(title: title,
                               notes: addingReference(to: origin, appointmentID: appointment.id), kind: .task)
        task.list = appointment.list
        // These are Alfred's own follow-ups, even if the appointment was assigned to staff.
        task.assignedTo = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        context.insert(task)
        do { try context.save() }
        catch {
            context.delete(task)
            throw error
        }
        return task
    }
}

extension PlannerItem {
    var followUpAppointmentID: UUID? { kind == .task ? FollowUpActions.appointmentID(in: notes) : nil }
    var displayNotes: String { FollowUpActions.displayNotes(notes) }
}
