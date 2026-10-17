// Regression tests for follow-ups using an isolated local SwiftData store.
// Run: xcrun swiftc -parse-as-library PlannerApp/Models/{PlannerItem,PlannerList,FollowUpActions}.swift scripts/test-follow-up-actions.swift -o /tmp/planner-follow-up-tests && /tmp/planner-follow-up-tests
import Foundation
import SwiftData

@main
struct FollowUpActionsTests {
    @MainActor static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("planner-follow-up-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("test.store")
        let schema = Schema([PlannerItem.self, PlannerList.self])
        let configuration = ModelConfiguration(schema: schema, url: store, cloudKitDatabase: .none)
        let appointmentID: UUID
        let actionIDs: [UUID]
        do {
            let container = try ModelContainer(for: schema, configurations: configuration)
            let context = ModelContext(container)
            let list = PlannerList(name: "Test client")
            context.insert(list)
            let appointment = PlannerItem(title: "Completed appointment", notes: "Original meeting notes", kind: .appointment,
                                          date: Date(timeIntervalSince1970: 1_700_000_000))
            appointment.list = list
            appointment.assignedTo = "Another staff member"
            appointment.toggleDone()
            context.insert(appointment)
            try context.save()
            appointmentID = appointment.id
            let snapshot = (appointment.title, appointment.notes, appointment.date, appointment.isDone, appointment.isArchived)
            let first = try FollowUpActions.add(title: "  Send meeting summary  ", to: appointment, ownerName: "Alfred", context: context)
            precondition(first.title == "Send meeting summary")
            precondition(first.kind == .task && first.date == nil && !first.isDone && !first.isArchived)
            precondition(first.isMine(ownerName: "Alfred") && first.assignedTo == "Alfred")
            precondition(first.list?.id == list.id && first.followUpAppointmentID == appointment.id)
            precondition(!first.displayNotes.contains("<!--") && first.displayNotes.contains(appointment.title))
            precondition(appointment.title == snapshot.0 && appointment.notes == snapshot.1 && appointment.date == snapshot.2)
            precondition(appointment.isDone == snapshot.3 && appointment.isArchived == snapshot.4)
            first.notes = FollowUpActions.notes("Edited task notes", preservingReferenceFrom: first.notes)
            precondition(first.followUpAppointmentID == appointment.id && first.displayNotes == "Edited task notes")
            let editedAgain = FollowUpActions.notes(first.notes, preservingReferenceFrom: first.notes)
            precondition(editedAgain.components(separatedBy: "planner-follow-up-appointment:").count == 2)
            let second = try FollowUpActions.add(title: "Prepare proposal", to: appointment, ownerName: "Alfred", context: context)
            actionIDs = [first.id, second.id]
            do {
                try FollowUpActions.add(title: " \n ", to: appointment, ownerName: "Alfred", context: context)
                preconditionFailure("Blank title was accepted")
            } catch FollowUpActions.ValidationError.emptyTitle {}
            do {
                try FollowUpActions.add(title: "Incorrect source", to: first, ownerName: "Alfred", context: context)
                preconditionFailure("To-Do was accepted as an appointment")
            } catch FollowUpActions.ValidationError.notAppointment {}
            try context.save()
            let total = try context.fetchCount(FetchDescriptor<PlannerItem>())
            precondition(total == 3)
        }
        do {
            let reopened = try ModelContainer(for: schema, configurations: configuration)
            let context = ModelContext(reopened)
            let items = try context.fetch(FetchDescriptor<PlannerItem>())
            let actions = items.filter { $0.followUpAppointmentID == appointmentID }
            precondition(Set(actions.map(\.id)) == Set(actionIDs) && actions.count == 2)
            precondition(actions.allSatisfy { $0.kind == .task && $0.isMine(ownerName: "Alfred") })
            let first = actions.first { $0.title == "Send meeting summary" }!
            precondition(first.displayNotes == "Edited task notes")
            first.toggleDone()
            try context.save()
            precondition(first.isDone && first.isArchived && first.followUpAppointmentID == appointmentID)
        }
        print("PASS: completed appointment follow-ups, owner visibility, multiple tasks, notes edits, validation, disk persistence and completion")
    }
}
