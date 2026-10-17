import SwiftUI
import SwiftData

/// Inline appointment actions; the same saved tasks also appear in the To-Do queue.
struct FollowUpActionsView: View {
    let appointment: PlannerItem
    @Environment(\.modelContext) private var context
    @AppStorage("ownerName") private var ownerName = "Alfred"
    @Query(filter: #Predicate<PlannerItem> { $0.kindRaw == "task" }, sort: \PlannerItem.createdAt)
    private var tasks: [PlannerItem]
    @State private var expanded: Bool
    @State private var draft = ""
    @State private var saveError: String?
    @State private var editingTask: PlannerItem?

    init(appointment: PlannerItem) {
        self.appointment = appointment
        _expanded = State(initialValue: appointment.isDone)
    }

    private var actions: [PlannerItem] {
        tasks.filter { $0.followUpAppointmentID == appointment.id && (!$0.isArchived || $0.isDone) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    Label("Follow Up Actions", systemImage: "checklist")
                    if !actions.isEmpty {
                        Text("(\(actions.count))").foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .font(.caption.weight(.semibold))
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("\(expanded ? "Collapse" : "Expand") Follow Up Actions for \(appointment.title)")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(actions) { task in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Button {
                                task.toggleDone()
                            } label: {
                                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(task.isDone ? Theme.accent : .secondary)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(task.isDone ? "Restore follow-up \(task.title)" : "Complete follow-up \(task.title)")
                            Button { editingTask = task } label: {
                                Text(task.title).strikethrough(task.isDone)
                                    .foregroundStyle(task.isDone ? .secondary : .primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Edit follow-up \(task.title)")
                            Text(task.isDone ? "Completed" : "In To-Do")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    HStack(alignment: .bottom, spacing: 8) {
                        TextField("Enter a follow-up task", text: $draft, axis: .vertical)
                            .lineLimit(1...3)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(add)
                            .accessibilityLabel("Follow-up task for \(appointment.title)")
                            .accessibilityIdentifier("appointment.followUpTitle")
                        Button("Add to To-Do", action: add)
                            .buttonStyle(.borderedProminent)
                            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("appointment.addFollowUp")
                    }
                    if let saveError { Text(saveError).foregroundStyle(.red).font(.caption) }
                }
                .font(.callout)
                .padding(.top, 6)
            }
        }
        .accessibilityElement(children: .contain)
        .tint(Theme.accent)
        .onChange(of: appointment.isDone) { _, done in if done { expanded = true } }
        .sheet(item: $editingTask) { AddItemView(item: $0) }
    }

    private func add() {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try FollowUpActions.add(title: draft, to: appointment, ownerName: ownerName, context: context)
            draft = ""
            saveError = nil
        } catch { saveError = error.localizedDescription }
    }
}
