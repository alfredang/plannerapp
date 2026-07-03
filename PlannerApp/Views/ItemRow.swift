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

                HStack(spacing: 6) {
                    Label(item.kind.title, systemImage: item.kind.symbol)
                        .labelStyle(.titleAndIcon)
                    if let date = item.date {
                        Text("•")
                        Text(date, format: dateFormat(for: item))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

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

    private func dateFormat(for item: PlannerItem) -> Date.FormatStyle {
        item.isAppointment
            ? .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()
            : .dateTime.month(.abbreviated).day()
    }
}
