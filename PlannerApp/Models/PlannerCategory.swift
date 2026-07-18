import Foundation

/// The smart list categories shared by the iPhone Planner tab and the Mac sidebar, so both
/// platforms present the same structure: smart categories first, then the user's own lists.
enum PlannerCategory: String, CaseIterable, Identifiable, Hashable {
    // `scheduled` keeps its raw value (it is persisted in UI state); only the label changed.
    case all, today, scheduled, pinned, todos, appointments

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:          return "To-Do"
        case .today:        return "Today"
        case .scheduled:    return "Reminders"
        case .pinned:       return "Pinned"
        case .todos:        return "To-Dos"
        case .appointments: return "Appointments"
        }
    }

    var symbol: String {
        switch self {
        case .all:          return "tray.full.fill"
        case .today:        return "star.fill"
        case .scheduled:    return "bell.fill"
        case .pinned:       return "pin.fill"
        case .todos:        return "checklist"
        case .appointments: return "calendar"
        }
    }

    /// Whether an active (non-archived) item belongs to this category.
    func contains(_ item: PlannerItem) -> Bool {
        switch self {
        case .all:
            return true
        case .today:
            guard let date = item.date else { return false }
            return Calendar.current.isDateInToday(date)
        case .scheduled:
            return item.date != nil
        case .pinned:
            return item.isPinned
        case .todos:
            return item.kind == .task
        case .appointments:
            return item.kind == .appointment
        }
    }
}

/// What the planner is currently filtered by: a smart category or one of the user's lists.
enum PlannerFilter: Hashable {
    case category(PlannerCategory)
    case list(UUID)
}
