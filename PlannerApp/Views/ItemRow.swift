import SwiftUI

/// A single planner row with a tappable checkbox. Checking the box auto-archives the item.
/// Tapping the row content opens the edit form (when `onEdit` is provided).
struct ItemRow: View {
    @Bindable var item: PlannerItem
    var onToggle: () -> Void
    var onEdit: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(item.isDone ? Theme.accent : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.isDone ? "Mark as not done" : "Mark as done")

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.body)
                    .strikethrough(item.isDone, color: .secondary)
                    .foregroundStyle(item.isDone ? .secondary : .primary)

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

                if !item.notes.isEmpty {
                    Text(item.notes)
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
    /// Badge colour: red for Critical, orange for High, grey for Low.
    var color: Color {
        switch self {
        case .critical: return .red
        case .high:     return .orange
        case .medium:   return .secondary
        case .low:      return .gray
        }
    }
}
