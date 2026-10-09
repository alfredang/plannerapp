import Foundation

/// First day of the week in the month calendar. User-selectable in Settings on both the
/// iPhone and Mac apps (device-local AppStorage); Monday by default.
enum WeekStart: Int, CaseIterable, Identifiable {
    // Values match `Calendar.firstWeekday` (1 = Sunday … 7 = Saturday).
    case sunday = 1, monday = 2, saturday = 7

    static let storageKey = "calendar.weekStart"
    static let defaultValue = WeekStart.monday

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .sunday:   return "Sunday"
        case .monday:   return "Monday"
        case .saturday: return "Saturday"
        }
    }

    /// The current calendar with this week start applied.
    var calendar: Calendar {
        var cal = Calendar.current
        cal.firstWeekday = rawValue
        return cal
    }
}
