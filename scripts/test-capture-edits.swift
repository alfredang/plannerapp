// Regression tests for the capture bar's edit routing (type or dictate "move X to 8pm").
// Run: xcrun swiftc -parse-as-library PlannerApp/Models/*.swift PlannerApp/Services/*.swift scripts/test-capture-edits.swift -o /tmp/planner-capture-tests && /tmp/planner-capture-tests
import Foundation
import SwiftData

@main
struct CaptureEditTests {
    static var failures = 0

    static func check(_ condition: Bool, _ message: String) {
        print(condition ? "PASS  \(message)" : "FAIL  \(message)")
        if !condition { failures += 1 }
    }

    static func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    @MainActor static func main() async throws {
        // Keyword routing (used when Apple Intelligence is unavailable).
        let change = PlannerCommand.keywordFallback("change Claude Foundation Exam to 8pm")
        check(change.action == .reschedule && change.target == "Claude Foundation Exam",
              "“change X to 8pm” is a reschedule of X (\(change.action), “\(change.target)”)")
        let postpone = PlannerCommand.keywordFallback("postpone the UOB training to Friday")
        check(postpone.action == .reschedule && postpone.target == "UOB training",
              "“postpone the X to Friday” is a reschedule of X (“\(postpone.target)”)")
        let rename = PlannerCommand.keywordFallback("change Team sync to Team standup")
        check(rename.action == .rename && rename.newTitle == "Team standup",
              "“change X to Y” without a date is a rename")
        check(PlannerCommand.keywordFallback("Lunch with Sam tomorrow 1pm").action == .add,
              "a plain new entry is still an add")

        // Time-only keeps the day; day-only keeps the time.
        let exam = PlannerItem(title: "Claude Foundation Exam (7:30pm–9:45pm)", kind: .appointment,
                               date: at(2026, 10, 22, 19, 30))
        let t = PlannerCommand.newDate(for: exam, from: "change Claude Foundation Exam to 8pm",
                                       target: "Claude Foundation Exam")
        check(t?.date == at(2026, 10, 22, 20, 0), "“to 8pm” keeps 22 Oct, sets 8 PM (\(String(describing: t?.date)))")
        let d = PlannerCommand.newDate(for: exam, from: "move Claude Foundation Exam to 29 Oct",
                                       target: "Claude Foundation Exam")
        check(d?.date == at(2026, 10, 29, 19, 30), "“to 29 Oct” keeps 7:30 PM (\(String(describing: d?.date)))")
        let both = PlannerCommand.newDate(for: exam, from: "move Claude Foundation Exam to 23 Oct 9pm",
                                          target: "Claude Foundation Exam")
        check(both?.date == at(2026, 10, 23, 21, 0), "“to 23 Oct 9pm” sets both (\(String(describing: both?.date)))")
        let inTitle = PlannerCommand.newDate(for: exam,
                                             from: "change Claude Foundation Exam (7:30pm–9:45pm) to 8pm",
                                             target: "Claude Foundation Exam (7:30pm–9:45pm)")
        check(inTitle?.date == at(2026, 10, 22, 20, 0), "a time inside the title isn't read as the new slot")

        // End to end against a real (local) store: the edit changes the existing row, no copy.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("planner-capture-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let schema = Schema([PlannerItem.self, PlannerList.self])
        let config = ModelConfiguration(schema: schema, url: dir.appendingPathComponent("t.store"),
                                        cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: config)
        let context = ModelContext(container)
        context.insert(exam)
        try context.save()

        let r = await PlannerCommand.handle("change Claude Foundation Exam to 8pm",
                                            context: context, ownerName: "Alfred")
        let all = try context.fetch(FetchDescriptor<PlannerItem>())
        check(r.action == .reschedule && r.didMutate, "router reschedules (\(r.action)): \(r.reply)")
        check(all.count == 1, "no duplicate appointment was created (\(all.count) items)")
        check(exam.date == at(2026, 10, 22, 20, 0), "the existing appointment moved to 8 PM")

        let list = PlannerList(name: "Ryan")
        context.insert(list)
        let add = await PlannerCommand.handle("Lunch with Sam 30 Oct 1pm", context: context,
                                              ownerName: "Alfred", defaultList: list)
        check(add.action == .add && add.item?.list === list, "a new entry is added into the open list")
        check(add.item?.kind == .appointment, "…as an appointment")

        // New entries that start with an edit verb must not be swallowed or hijack a row.
        let site = await PlannerCommand.handle("Update the company website by 30 Oct",
                                               context: context, ownerName: "Alfred")
        check(site.action == .add && site.item?.title.lowercased().contains("website") == true,
              "“Update the company website by 30 Oct” is added as a new to-do (\(site.action))")
        let lunchDate = add.item?.date
        let furniture = await PlannerCommand.handle("move furniture with Sam 31 Oct 3pm",
                                                    context: context, ownerName: "Alfred")
        check(furniture.action == .add && add.item?.date == lunchDate,
              "a one-word overlap (“Sam”) doesn't reschedule the lunch (\(furniture.action))")
        let moveExam = await PlannerCommand.handle("move the Claude exam to 9pm",
                                                   context: context, ownerName: "Alfred")
        check(moveExam.action == .reschedule && exam.date == at(2026, 10, 22, 21, 0),
              "a short name for the exam still reschedules it")

        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
