import SwiftUI
import SwiftData

/// Manual add/edit form for a to-do or appointment.
struct AddItemView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    /// Optional prefill (used when confirming a voice-parsed entry).
    var prefill: ParsedEntry?

    @State private var title = ""
    @State private var notes = ""
    @State private var kind: PlannerKind = .task
    @State private var includeDate = false
    @State private var date = Date()

    init(prefill: ParsedEntry? = nil) {
        self.prefill = prefill
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $kind) {
                        ForEach(PlannerKind.allCases) { k in
                            Label(k.title, systemImage: k.symbol).tag(k)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Details") {
                    TextField("Title", text: $title, axis: .vertical)
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                }

                Section {
                    Toggle("Set date & time", isOn: $includeDate)
                    if includeDate {
                        DatePicker("When", selection: $date)
                            .datePickerStyle(.compact)
                    }
                }
            }
            .navigationTitle(kind == .task ? "New To-Do" : "New Appointment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!canSave)
                }
            }
            .onAppear(perform: applyPrefill)
            .onChange(of: kind) { _, newKind in
                // Appointments need a time; default it on when switching.
                if newKind == .appointment && !includeDate { includeDate = true }
            }
        }
    }

    private func applyPrefill() {
        guard let prefill else { return }
        title = prefill.title
        kind = prefill.kind
        if let d = prefill.date {
            date = d
            includeDate = true
        }
    }

    private func save() {
        let item = PlannerItem(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: kind,
            date: includeDate ? date : nil
        )
        context.insert(item)
        dismiss()
    }
}

#Preview {
    AddItemView()
        .modelContainer(for: PlannerItem.self, inMemory: true)
}
