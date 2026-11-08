import Foundation

/// What the owner should follow up on: Critical to-dos, and to-dos and goals past their date.
/// "Overdue" means the same as the app's Overdue section: the date is before today. Appointments
/// are left out, since a past one isn't overdue: it waits for "Did this happen?".
enum FollowUpDigest {
    /// A long message is no use on a phone; the rest are in Planner.
    private static let maxLines = 20

    struct Open {
        var critical: [PlannerItem]
        var overdue: [PlannerItem]
        var isEmpty: Bool { critical.isEmpty && overdue.isEmpty }
        var ids: [String] { (critical + overdue).map(\.id.uuidString) }

        func excluding(_ ids: Set<String>) -> Open {
            Open(critical: critical.filter { !ids.contains($0.id.uuidString) },
                 overdue: overdue.filter { !ids.contains($0.id.uuidString) })
        }
    }

    /// An item that is both is listed once, under Critical. Oldest date first, undated last.
    static func open(in items: [PlannerItem], now: Date) -> Open {
        let today = Calendar.current.startOfDay(for: now)
        let active = items.filter { !$0.isDone && !$0.isArchived }
        let critical = active.filter { $0.kind == .task && $0.priority == .critical }
        let overdue = active.filter { item in
            guard item.kind == .goal || (item.kind == .task && item.priority != .critical),
                  let date = item.date else { return false }
            return date < today
        }
        let byDate: (PlannerItem, PlannerItem) -> Bool = {
            ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture)
        }
        return Open(critical: critical.sorted(by: byDate), overdue: overdue.sorted(by: byDate))
    }

    static func message(_ open: Open, now: Date) -> String {
        let today = Calendar.current.startOfDay(for: now)
        var lines = ["🔔 *Needs your follow-up* — \(dayLabel(now))"]
        var room = maxLines

        func add(_ heading: String, _ items: [PlannerItem]) {
            guard !items.isEmpty, room > 0 else { return }
            lines += ["", "*\(heading)*"]
            for item in items.prefix(room) { lines.append(line(for: item, today: today)) }
            room -= min(room, items.count)
        }
        add("Critical", open.critical)
        add("Overdue", open.overdue)

        let hidden = open.critical.count + open.overdue.count - maxLines
        if hidden > 0 { lines += ["", "…and \(hidden) more in Planner."] }
        lines += ["", "— Planner"]
        return lines.joined(separator: "\n")
    }

    private static func line(for item: PlannerItem, today: Date) -> String {
        var line = "• \(item.title)"
        if let date = item.date {
            line += date < today ? " — was due \(dayLabel(date))" : " — due \(dayLabel(date))"
        }
        var details: [String] = []
        if let list = item.list?.name { details.append(list) }
        let who = item.assignedTo.trimmingCharacters(in: .whitespacesAndNewlines)
        if !who.isEmpty { details.append(who) }
        if !details.isEmpty { line += " (\(details.joined(separator: ", ")))" }
        return line
    }

    private static func dayLabel(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}
