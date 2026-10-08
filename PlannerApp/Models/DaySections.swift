import Foundation

/// One day's worth of dated items in the Upcoming view — or, with `day == nil`, the
/// "Overdue" bucket for active items whose date has already passed.
struct DaySection: Identifiable {
    let day: Date?
    let items: [PlannerItem]

    var id: Date { day ?? .distantPast }

    var title: String { day.map { DaySections.title(for: $0) } ?? "Overdue" }
}

/// Breaks dated items down by date for the Upcoming view (iPhone and Mac alike): anything
/// already past goes in one "Overdue" section first, then one section per day from today
/// onwards. Each section runs in time order.
enum DaySections {
    static func group(_ items: [PlannerItem], now: Date = Date()) -> [DaySection] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let dated = items
            .filter { $0.date != nil }
            .sorted { ($0.date!, $0.title) < ($1.date!, $1.title) }

        var sections: [DaySection] = []
        let overdue = dated.filter { $0.date! < today }
        if !overdue.isEmpty { sections.append(DaySection(day: nil, items: overdue)) }

        let byDay = Dictionary(grouping: dated.filter { $0.date! >= today }) {
            cal.startOfDay(for: $0.date!)
        }
        for day in byDay.keys.sorted() {
            sections.append(DaySection(day: day, items: byDay[day] ?? []))
        }
        return sections
    }

    /// "Today · Wednesday, 8 October", "Tomorrow · …", or the plain date (plus the year
    /// when it isn't this year).
    static func title(for day: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let full = day.formatted(.dateTime.weekday(.wide).day().month(.wide))
        if cal.isDate(day, inSameDayAs: now) { return "Today · \(full)" }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now),
           cal.isDate(day, inSameDayAs: tomorrow) { return "Tomorrow · \(full)" }
        let sameYear = cal.component(.year, from: day) == cal.component(.year, from: now)
        return sameYear ? full : "\(full) \(cal.component(.year, from: day))"
    }
}
