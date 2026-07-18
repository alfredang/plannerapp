import SwiftUI
import SwiftData

/// Manual add/edit form for a to-do or appointment.
struct AddItemView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    /// Optional prefill (used when confirming a voice-parsed entry).
    var prefill: ParsedEntry?

    /// When set, the form edits this existing item in place instead of creating a new one.
    var itemToEdit: PlannerItem?

    /// Pre-selected list for new items (e.g. the list currently open in the UI).
    var defaultList: PlannerList?

    @Query(sort: \PlannerList.createdAt) private var lists: [PlannerList]

    @State private var title = ""
    @State private var notes = ""
    @State private var kind: PlannerKind = .task
    @State private var includeDate = false
    @State private var date = Date()
    @State private var selectedListID: UUID?
    @State private var assignedTo = ""
    /// Armed after prefill so the date-toggle → appointment auto-switch only reacts to
    /// the user, not to loading an existing dated to-do into the form.
    @State private var autoKindEnabled = false

    init(prefill: ParsedEntry? = nil, defaultList: PlannerList? = nil) {
        self.prefill = prefill
        self.defaultList = defaultList
    }

    init(item: PlannerItem) {
        self.itemToEdit = item
    }

    private var isEditing: Bool { itemToEdit != nil }

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
                        .lineLimit(1...4)

                    // A real multi-line box that grows as you type. `TextField` with a
                    // placeholder renders that placeholder as a leading *label* on macOS,
                    // squeezing long notes into a narrow right-hand column — so use a
                    // TextEditor with our own placeholder overlay instead.
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Notes (optional)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 4)
                        ZStack(alignment: .topLeading) {
                            TextEditor(text: $notes)
                                .frame(minHeight: 90, maxHeight: 260)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .multilineTextAlignment(.leading)
                                .scrollContentBackground(.hidden)
                                .font(.body)
                            if notes.isEmpty {
                                // Placeholder — hit-testing off so taps reach the editor.
                                Text("Add any details…")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

                Section {
                    Toggle("Set date & time", isOn: $includeDate)
                    if includeDate {
                        DatePicker("When", selection: $date)
                            .datePickerStyle(.compact)
                    }
                }

                // Escape hatch for existing dated to-dos (created before the automatic
                // conversion): one flick moves it into Appointments.
                if kind == .task && includeDate {
                    Section {
                        Toggle("Add to Appointments", isOn: Binding(
                            get: { false },
                            set: { if $0 { withAnimation { kind = .appointment } } }
                        ))
                    } footer: {
                        Text("A dated to-do stays under To-Do. Turn this on to make it an appointment.")
                    }
                }

                if !lists.isEmpty {
                    Section {
                        Picker("List", selection: $selectedListID) {
                            Text("None").tag(UUID?.none)
                            ForEach(lists) { list in
                                Label(list.name, systemImage: "folder").tag(Optional(list.id))
                            }
                        }
                    }
                }

                Section {
                    TextField("Assign to (optional)", text: $assignedTo)
                        #if os(iOS)
                        .textInputAutocapitalization(.words)
                        #endif
                }
            }
            .navigationTitle(navigationTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
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
            .onChange(of: selectedListID) { oldID, newID in
                // Moving the item into someone's list assigns it to them. Only fills a
                // blank field, or replaces the previous list's owner — never a name the
                // user typed themselves.
                guard autoKindEnabled else { return }   // ignore the prefill pass
                let previousOwner = lists.first { $0.id == oldID }?.derivedAssignee
                let newOwner = lists.first { $0.id == newID }?.derivedAssignee
                let current = assignedTo.trimmingCharacters(in: .whitespacesAndNewlines)
                if current.isEmpty || current == previousOwner {
                    assignedTo = newOwner ?? ""
                }
            }
            .onChange(of: includeDate) { _, isOn in
                // Setting a date & time makes it an appointment automatically
                // (tap To-Do again afterwards if you want a dated to-do). Only for
                // user toggles — prefilling an existing dated to-do must not convert it.
                if isOn && kind == .task && autoKindEnabled {
                    withAnimation { kind = .appointment }
                }
                // An appointment with no date is meaningless: clearing the date
                // moves it back to To-Do so the toggle can actually be turned off.
                if !isOn && kind == .appointment && autoKindEnabled {
                    withAnimation { kind = .task }
                }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 320)
        #endif
    }

    private var navigationTitle: String {
        if isEditing {
            return kind == .task ? "Edit To-Do" : "Edit Appointment"
        }
        return kind == .task ? "New To-Do" : "New Appointment"
    }

    private func applyPrefill() {
        // Arm the auto-switch only after this prefill pass has rendered.
        defer { Task { @MainActor in autoKindEnabled = true } }
        if let itemToEdit {
            title = itemToEdit.title
            notes = itemToEdit.notes
            kind = itemToEdit.kind
            selectedListID = itemToEdit.list?.id
            assignedTo = itemToEdit.assignedTo
            if let d = itemToEdit.date {
                date = d
                includeDate = true
            }
            return
        }
        selectedListID = defaultList?.id
        // Adding inside someone's list assigns it to them ("Ryan Ngau (NUS)" → "Ryan"), so
        // it lands in their queue and out of yours. Editable — this is only a default.
        if let assignee = defaultList?.derivedAssignee { assignedTo = assignee }
        guard let prefill else { return }
        title = prefill.title
        kind = prefill.kind
        if let d = prefill.date {
            date = d
            includeDate = true
        }
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let list = lists.first { $0.id == selectedListID }

        let trimmedAssignee = assignedTo.trimmingCharacters(in: .whitespacesAndNewlines)

        let saved: PlannerItem
        if let itemToEdit {
            itemToEdit.title = trimmedTitle
            itemToEdit.notes = trimmedNotes
            itemToEdit.kind = kind
            itemToEdit.date = includeDate ? date : nil
            itemToEdit.list = list
            itemToEdit.assignedTo = trimmedAssignee
            saved = itemToEdit
        } else {
            let item = PlannerItem(
                title: trimmedTitle,
                notes: trimmedNotes,
                kind: kind,
                date: includeDate ? date : nil
            )
            item.list = list
            item.assignedTo = trimmedAssignee
            context.insert(item)
            saved = item
        }
        // Mirror the appointment into the system Calendar (and onward to Google, if that
        // account is set up there). No-op unless the user enabled calendar sync.
        if let eventID = CalendarSync.sync(saved) { saved.calendarEventID = eventID }

        // Re-arm the advance alerts so a new/changed date takes effect immediately.
        let ctx = context
        Task { await ReminderScheduler.rescheduleAll(context: ctx) }
        dismiss()
    }
}

#Preview {
    AddItemView()
        .modelContainer(for: PlannerItem.self, inMemory: true)
}
