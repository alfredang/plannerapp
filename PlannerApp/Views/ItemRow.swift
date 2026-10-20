import SwiftUI

/// A single planner row with a tappable checkbox. Checking the box auto-archives the item.
/// Tapping the row content opens the edit form (when `onEdit` is provided).
struct ItemRow: View {
    @Bindable var item: PlannerItem
    var onToggle: () -> Void
    var onEdit: (() -> Void)? = nil

    @Environment(\.openURL) private var openURL
    @Environment(\.modelContext) private var context

    /// "Reply / comment" opens an inline box under the row (not the edit form).
    @State private var isCommenting = false
    @State private var commentDraft = ""
    @FocusState private var commentFocused: Bool
    /// "Rescheduled" opens an inline date picker for the new slot.
    @State private var isRescheduling = false
    @State private var rescheduleDate = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            detailsRow
            // Kept outside `detailsRow`: its tap opens the edit form and it reads as one
            // combined accessibility element, so buttons and the comment box in there
            // would be swallowed by the row.
            if item.isAppointment {
                appointmentStatus
                    .padding(.leading, 40)
            }
            if item.isAppointment {
                FollowUpActionsView(appointment: item)
                    .padding(.leading, 40)
            }
        }
    }

    private var detailsRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(item.isDone ? Theme.accent : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.isDone ? "Mark as not done" : "Mark as done")

            VStack(alignment: .leading, spacing: 4) {
                let closed = item.isDone || item.isCancelled
                Text(item.title)
                    .font(.body)
                    .strikethrough(closed, color: .secondary)
                    .foregroundStyle(closed ? .secondary : .primary)

                // One wrapping Text (not an HStack): on narrow rows it flows like prose
                // instead of squeezing each label into a one-character-wide column.
                caption
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Own line so it never gets squeezed out of the caption row.
                if !item.assignedTo.isEmpty {
                    Label(item.assignedTo, systemImage: "person.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.accent)
                }

                // One-tap join for virtual appointments (link found in the notes).
                if let url = item.meetingURL {
                    Button {
                        openURL(url)
                    } label: {
                        Label("Join meeting", systemImage: "video.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Theme.accent.opacity(0.15), in: Capsule())
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.borderless)
                    #if os(macOS)
                    .help(url.absoluteString)
                    #endif
                    .accessibilityLabel("Join meeting")
                    .accessibilityHint(url.absoluteString)
                }

                let notesPreview = AppointmentComments.withoutComments(item.displayNotes)
                if !notesPreview.isEmpty {
                    Text(notesPreview)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { onEdit?() }
        .accessibilityElement(children: .combine)
        .accessibilityHint(onEdit != nil ? "Double tap to edit" : "")
    }

    /// Past appointments: ticked = completed. Unticked ones ask instead of judging — the
    /// app can't know it happened — with one-tap answers (happened, cancelled, rescheduled,
    /// or a comment). Then any comments, and the box.
    @ViewBuilder
    private var appointmentStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            if item.isDone {
                Label("Completed", systemImage: "checkmark.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            } else if item.isCancelled {
                HStack(spacing: 10) {
                    Label("Cancelled", systemImage: "xmark.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                    Button("Undo") { setCancelled(false) }
                        .font(.caption)
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Undo cancelled")
                        .accessibilityIdentifier("appointment.undoCancelled")
                }
            } else if item.isMissed {
                // Once he has replied, the question is answered — stop shouting it.
                if item.comments.isEmpty {
                    Label("Did this happen?", systemImage: "questionmark.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.orange)
                } else {
                    Label("Replied — tick it if it did happen", systemImage: "checkmark.bubble")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                // One row when they fit, two on a narrower row, stacked on a narrow iPhone.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { yesButton; cancelledButton; rescheduledButton; replyButton }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) { yesButton; cancelledButton }
                        HStack(spacing: 8) { rescheduledButton; replyButton }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        yesButton; cancelledButton; rescheduledButton; replyButton
                    }
                }
                .buttonStyle(.borderless)
                if isRescheduling {
                    rescheduleComposer
                }
            }
            // Comments posted from "Reply / comment", oldest first, with the agent's answers.
            ForEach(item.comments, id: \.self) { comment in
                if let agent = comment.author {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(Theme.accent)
                        (Text("\(agent): ").fontWeight(.semibold).foregroundColor(Theme.accent)
                            + Text(comment.text).foregroundColor(.primary)
                            + Text("  \(comment.stamp)").foregroundColor(.secondary))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "text.bubble")
                            .foregroundStyle(Theme.accent)
                        Text(comment.text).foregroundStyle(.primary)
                            + Text("  \(comment.stamp)").foregroundStyle(.tertiary)
                    }
                    .font(.caption)
                }
            }
            #if os(macOS)
            agentStatus
            #endif
            if isCommenting {
                commentComposer
            }
        }
    }

    private var yesButton: some View {
        Button(action: onToggle) {
            Label("Yes, it happened", systemImage: "checkmark")
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Theme.accent.opacity(0.15), in: Capsule())
                .foregroundStyle(Theme.accent)
        }
        .fixedSize()
        .accessibilityIdentifier("appointment.happened")
    }

    private var cancelledButton: some View {
        Button { setCancelled(true) } label: {
            Label("Cancelled", systemImage: "xmark")
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Color.red.opacity(0.12), in: Capsule())
                .foregroundStyle(.red)
        }
        .fixedSize()
        .accessibilityIdentifier("appointment.cancelled")
    }

    private var rescheduledButton: some View {
        Button(action: startReschedule) {
            Label("Rescheduled", systemImage: "calendar.badge.clock")
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Color.orange.opacity(isRescheduling ? 0.25 : 0.12), in: Capsule())
                .foregroundStyle(.orange)
        }
        .fixedSize()
        .accessibilityIdentifier("appointment.rescheduled")
    }

    private var replyButton: some View {
        Button(action: startComment) {
            Label("Reply / comment", systemImage: "text.bubble")
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Color.secondary.opacity(isCommenting ? 0.25 : 0.12), in: Capsule())
                .foregroundStyle(.primary)
        }
        .fixedSize()
        .accessibilityIdentifier("appointment.reply")
    }

    private var commentComposer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Write a comment…", text: $commentDraft, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .focused($commentFocused)
                .onSubmit(postComment)
                .accessibilityLabel("Comment on \(item.title)")
                .accessibilityIdentifier("appointment.commentText")
            Button("Post", action: postComment)
                .buttonStyle(.borderedProminent)
                .disabled(commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("appointment.postComment")
            Button("Cancel") {
                withAnimation { isCommenting = false }
                commentDraft = ""
            }
            .buttonStyle(.borderless)
        }
        .font(.callout)
        .tint(Theme.accent)
    }

    private var rescheduleComposer: some View {
        HStack(spacing: 8) {
            DatePicker("Moved to", selection: $rescheduleDate,
                       displayedComponents: [.date, .hourAndMinute])
                .accessibilityIdentifier("appointment.rescheduleDate")
            Button("Move", action: confirmReschedule)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("appointment.confirmReschedule")
            Button("Close") {
                withAnimation { isRescheduling = false }
            }
            .buttonStyle(.borderless)
        }
        .font(.callout)
        .tint(Theme.accent)
    }

    private func setCancelled(_ cancelled: Bool) {
        withAnimation {
            if cancelled { item.markCancelled() } else { item.undoCancelled() }
            isRescheduling = false
        }
        saveAndSync()
        #if os(macOS)
        if cancelled { AppointmentAgent.shared.ask(item) }
        #endif
    }

    private func startReschedule() {
        // Starts from the same time tomorrow, so usually only the day needs changing.
        if !isRescheduling, let date = item.date {
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
            let time = Calendar.current.dateComponents([.hour, .minute], from: date)
            rescheduleDate = Calendar.current.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0,
                                                   second: 0, of: tomorrow) ?? tomorrow
        }
        withAnimation {
            isRescheduling.toggle()
            isCommenting = false
        }
    }

    private func confirmReschedule() {
        withAnimation {
            item.reschedule(to: rescheduleDate)
            isRescheduling = false
        }
        saveAndSync()
        #if os(macOS)
        AppointmentAgent.shared.ask(item)
        #endif
    }

    /// Saves straight away (so the iPhone and the agents see it), moves the mirrored
    /// calendar event, and re-arms the reminders for the new slot.
    private func saveAndSync() {
        if let eventID = CalendarSync.sync(item) { item.calendarEventID = eventID }
        try? context.save()
        Task { await ReminderScheduler.rescheduleAll(context: context) }
    }

    private func startComment() {
        withAnimation {
            isCommenting.toggle()
            isRescheduling = false
        }
        if isCommenting {
            // Focus once the field exists.
            DispatchQueue.main.async { commentFocused = true }
        }
    }

    private func postComment() {
        guard !commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        item.addComment(commentDraft)
        // Save now so the comment reaches the other devices (and the agents) straight away.
        try? context.save()
        commentDraft = ""
        withAnimation { isCommenting = false }
        #if os(macOS)
        // Atlas answers right away, under the comment.
        AppointmentAgent.shared.ask(item)
        #endif
    }

    #if os(macOS)
    /// "Atlas is checking…" while it works on the newest comment, or why it couldn't answer.
    @ViewBuilder
    private var agentStatus: some View {
        let agent = AppointmentAgent.shared
        if agent.pending.contains(item.id) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("\(AppointmentAgent.agentName) is checking the next move…")
            }
            .font(.caption.italic())
            .foregroundStyle(.secondary)
        } else if let note = agent.failed[item.id], item.unansweredComment != nil {
            Text(note)
                .font(.caption.italic())
                .foregroundStyle(.secondary)
        }
    }
    #endif

    private var caption: Text {
        var text = Text("\(Image(systemName: item.kind.symbol)) \(item.kind.title)")
        // Priority leads the caption on to-dos; Medium is the default, so it stays quiet.
        if item.kind == .task, item.priority != .medium {
            let p = item.priority
            text = Text("\(Image(systemName: p.symbol)) \(p.title)")
                .fontWeight(.semibold)
                .foregroundColor(p.color) + Text("  •  ") + text
        }
        if let date = item.date {
            // An appointment's date is its slot; a to-do's date is a deadline — say so.
            let prefix = item.isAppointment ? "" : "Due "
            text = text + Text("  •  \(prefix)") + Text(date, format: dateFormat(for: item))
        }
        if let list = item.list {
            text = text + Text("  •  ") + Text("\(Image(systemName: "folder")) \(list.name)")
        }
        return text
    }

    private func dateFormat(for item: PlannerItem) -> Date.FormatStyle {
        item.isAppointment
            ? .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()
            : .dateTime.month(.abbreviated).day()
    }
}

extension PlannerPriority {
    /// Priority colour: red Critical, orange High, blue Medium, green Low.
    var color: Color {
        switch self {
        case .critical: return .red
        case .high:     return .orange
        case .medium:   return .blue
        case .low:      return .green
        }
    }

    /// The symbol drawn in its colour for menus, which otherwise repaint every icon in
    /// one tint (AppKit / UIKit menus treat SF Symbols as templates).
    func coloredIcon(_ name: String? = nil, pointSize: CGFloat? = nil) -> Image {
        let symbol = name ?? self.symbol
        #if os(macOS)
        // Flattened into a plain bitmap: a symbol image (even a palette one) is still
        // re-tinted as a template inside menus and borderless menu buttons.
        let config = NSImage.SymbolConfiguration(pointSize: pointSize ?? 13, weight: .regular)
        if let symbolImage = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(config) {
            let tint = NSColor(color)
            let image = NSImage(size: symbolImage.size, flipped: false) { rect in
                symbolImage.draw(in: rect)
                tint.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            image.isTemplate = false
            return Image(nsImage: image).renderingMode(.original)
        }
        #else
        if let image = UIImage(systemName: symbol)?
            .withTintColor(UIColor(color), renderingMode: .alwaysOriginal) {
            return Image(uiImage: image).renderingMode(.original)
        }
        #endif
        return Image(systemName: symbol)
    }
}

/// Critical / High / Medium / Low, each in its colour, with a tick on the current one.
/// Shared by the flag menu and the row context menus on iPhone and Mac.
struct PriorityMenuItems: View {
    @Bindable var item: PlannerItem

    var body: some View {
        Picker("Priority", selection: Binding(
            get: { item.priority },
            set: { p in withAnimation { item.setPriority(p) } }
        )) {
            ForEach(PlannerPriority.ordered) { p in
                Label { Text(p.title) } icon: { p.coloredIcon() }
                    .tag(p)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}

/// The flag on a to-do row: shows the priority at a glance and changes it in one tap
/// (Critical and High pin automatically — see `PlannerItem.setPriority`).
struct PriorityMenuButton: View {
    @Bindable var item: PlannerItem
    var size: CGFloat = 15

    var body: some View {
        Menu {
            PriorityMenuItems(item: item)
        } label: {
            // Filled for every priority, always in its colour.
            let flag = "flag.fill"
            Group {
                #if os(macOS)
                // A borderless menu button repaints a plain symbol in the accent colour,
                // so the flag is drawn pre-coloured.
                item.priority.coloredIcon(flag, pointSize: size)
                #else
                Image(systemName: flag)
                    .font(.system(size: size))
                    .foregroundStyle(item.priority.color)
                #endif
            }
            .frame(width: size + 13, height: size + 13)
            .contentShape(Rectangle())
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Priority: \(item.priority.title)")
        #else
        .buttonStyle(.borderless)
        #endif
        .accessibilityLabel("Priority: \(item.priority.title)")
    }
}
