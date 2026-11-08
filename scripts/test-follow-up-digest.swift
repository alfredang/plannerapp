// Regression tests for the critical and overdue alert: an in-memory store, and nothing is sent.
// Run: xcrun swiftc -D DEBUG -parse-as-library PlannerApp/Models/{PlannerItem,PlannerList,FollowUpActions,PageLink,AppointmentComments}.swift PlannerApp/Services/SmartParser.swift PlannerAppMac/Services/FollowUpDigest.swift scripts/test-follow-up-digest.swift -o /tmp/planner-follow-up-digest-tests && /tmp/planner-follow-up-digest-tests
import Foundation
import SwiftData

@main
@MainActor
struct FollowUpDigestTests {
    static var failures = 0

    static func check(_ condition: Bool, _ label: String) {
        print("\(condition ? "PASS" : "FAIL"): \(label)")
        if !condition { failures += 1 }
    }

    static func main() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: PlannerItem.self, PlannerList.self, configurations: config)
        let context = container.mainContext
        let cal = Calendar.current
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 12))!
        let today = cal.startOfDay(for: now)
        let day = { (offset: Int) in cal.date(byAdding: .day, value: offset, to: today)! }

        func item(_ title: String, kind: PlannerKind = .task, date: Date? = nil,
                  priority: PlannerPriority = .medium) -> PlannerItem {
            let made = PlannerItem(title: title, kind: kind, date: date)
            made.priority = priority
            context.insert(made)
            return made
        }

        let future = item("critical later", date: day(6), priority: .critical)
        _ = item("critical no date", priority: .critical)
        let both = item("critical and late", date: day(-2), priority: .critical)
        let late = item("late", date: day(-3))
        let lateGoal = item("late goal", kind: .goal, date: day(-1))
        _ = item("due today", date: today)
        _ = item("due later", date: day(2))
        _ = item("past appointment", kind: .appointment, date: day(-4))
        _ = item("critical appointment", kind: .appointment, date: day(1), priority: .critical)
        _ = item("old page", kind: .page, date: day(-4))
        _ = item("old idea", kind: .idea, date: day(-4))
        let done = item("late but done", date: day(-5)); done.isDone = true
        let archived = item("late but archived", date: day(-5), priority: .critical); archived.isArchived = true

        let items = try context.fetch(FetchDescriptor<PlannerItem>())
        let open = FollowUpDigest.open(in: items, now: now)
        let critical = open.critical.map(\.title), overdue = open.overdue.map(\.title)

        check(critical == ["critical and late", "critical later", "critical no date"],
              "critical to-dos, oldest first, undated last")
        check(overdue == ["late", "late goal"], "overdue to-dos and goals, oldest first")
        check(!overdue.contains("critical and late"), "an item that is both is listed once")
        check(!overdue.contains("due today"), "due today isn't overdue yet")
        check(!(critical + overdue).contains { $0.contains("appointment") }, "appointments are left out")
        check(!(critical + overdue).contains { $0.contains("page") || $0.contains("idea") }, "pages and ideas are left out")
        check(!(critical + overdue).contains { $0.contains("done") || $0.contains("archived") }, "finished items are left out")

        let text = FollowUpDigest.message(open, now: now)
        check(text.contains("*Critical*") && text.contains("*Overdue*"), "the message has both headings")
        check(text.contains("critical and late — was due"), "a late critical says it was due")
        check(text.contains("critical later — due"), "a future critical says when it's due")

        // Alerted items aren't repeated the same day; a new one is.
        let alerted = Set(open.ids)
        check(open.excluding(alerted).isEmpty, "nothing new after everything has been alerted")
        let fresh = item("new critical", priority: .critical)
        let later = FollowUpDigest.open(in: try context.fetch(FetchDescriptor<PlannerItem>()), now: now)
        check(later.excluding(alerted).critical.map(\.id) == [fresh.id], "a new critical alerts on its own")

        // Finishing an item clears it.
        late.isDone = true; lateGoal.isDone = true; future.isDone = true; both.isDone = true
        let after = FollowUpDigest.open(in: try context.fetch(FetchDescriptor<PlannerItem>()), now: now)
        check(after.overdue.isEmpty, "done items stop alerting")

        // A long list is capped and says so.
        for n in 0..<30 { _ = item("late \(n)", date: day(-1)) }
        let many = FollowUpDigest.open(in: try context.fetch(FetchDescriptor<PlannerItem>()), now: now)
        let long = FollowUpDigest.message(many, now: now)
        check(long.split(separator: "\n").filter { $0.hasPrefix("• ") }.count == 20, "at most 20 lines")
        check(long.contains("…and 12 more in Planner."), "the rest are counted")

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
