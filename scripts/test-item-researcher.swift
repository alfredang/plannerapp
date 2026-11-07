// Regression tests for goal and idea research (ItemResearcher): an in-memory store and a fake
// research script, so nothing real is researched, published or synced.
// Run: xcrun swiftc -D DEBUG -parse-as-library PlannerApp/Models/{PlannerItem,PlannerList,FollowUpActions,PageLink,AppointmentComments}.swift PlannerApp/Services/SmartParser.swift PlannerAppMac/Services/ItemResearcher.swift scripts/test-item-researcher.swift -o /tmp/planner-item-researcher-tests && /tmp/planner-item-researcher-tests
import Foundation
import SwiftData

/// The one thing ItemResearcher needs from the Mac app's bridge.
enum HermesBridge {
    static let workspaceURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("planner-research-test-" + UUID().uuidString)
}

@main
struct ItemResearcherTests {
    nonisolated(unsafe) static var failures = 0

    static func check(_ condition: Bool, _ name: String) {
        print((condition ? "ok   " : "FAIL ") + name)
        if !condition { failures += 1 }
    }

    /// Fake script: logs its call; a title with FAIL fails unless forced, SLOW takes longer;
    /// otherwise it writes a page under the workspace and prints the link.
    static func writeFakeScript(to url: URL, log: URL) throws {
        let script = #"""
        #!/bin/zsh
        print -r -- "$1|$3|force=$RESEARCH_FORCE|target=$TARGET|goals=${GOALS//$'\n'/;}|details=$4" >> "\#(log.path)"
        [[ "$3" == *FAIL* && -z "$RESEARCH_FORCE" ]] && exit 1
        [[ "$3" == *SLOW* ]] && sleep 1.5
        short="${2:l}"; short="${short[1,8]}"
        mkdir -p "\#(HermesBridge.workspaceURL.path)/item-pages"
        print "<html></html>" > "\#(HermesBridge.workspaceURL.path)/item-pages/$short.html"
        print "some progress line"
        print "item-pages/$short.html"
        """#
        try script.write(to: url, atomically: true, encoding: .utf8)
    }

    @MainActor static func wait(_ what: String, until condition: () -> Bool) async {
        for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(100)) }
        if !condition() { print("timed out waiting for \(what)") }
    }

    @MainActor static func main() async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: HermesBridge.workspaceURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: HermesBridge.workspaceURL) }
        let script = HermesBridge.workspaceURL.appendingPathComponent("fake.sh")
        let log = HermesBridge.workspaceURL.appendingPathComponent("calls.log")
        try writeFakeScript(to: script, log: log)
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "itemResearcher.attempted")
        defer { defaults.removeObject(forKey: "itemResearcher.attempted"); defaults.removeObject(forKey: "researchScript") }
        defaults.set(script.path, forKey: "researchScript")
        func calls() -> [String] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        // Capture parsing
        let short = ItemResearcher.parts(of: "  Sell a tutor add-on  ")
        check(short.title == "Sell a tutor add-on" && short.notes.isEmpty, "short text is the title, no notes")
        let long = String(repeating: "word ", count: 40).trimmingCharacters(in: .whitespaces)
        let longParts = ItemResearcher.parts(of: long)
        check(longParts.title.count <= 81 && longParts.title.hasSuffix("word…") && longParts.notes == long,
              "long text cut at a word, full wording kept in notes")
        let lines = ItemResearcher.parts(of: "Headline\nMore detail")
        check(lines.title == "Headline" && lines.notes == "Headline\nMore detail", "first line is the title")

        let cal = Calendar.current
        func ymd(_ d: Date?) -> [Int?] {
            guard let d else { return [] }
            let c = cal.dateComponents([.year, .month, .day], from: d)
            return [c.year, c.month, c.day]
        }
        check(ymd(ItemResearcher.goalTarget(in: "More than 5 franchisees by 2027")) == [2027, 12, 31], "“by 2027” is the end of 2027")
        check(ymd(ItemResearcher.goalTarget(in: "Offer SCTP programs in 2030")) == [2030, 12, 31], "“in 2030” is the end of 2030")
        check(ymd(ItemResearcher.goalTarget(in: "Launch kids courses by 31 March 2030")) == [2030, 3, 31], "a full date is kept")
        check(ItemResearcher.goalTarget(in: "Bring up the Practice Exam business") == nil, "no date, no target")
        check(ItemResearcher.goalTarget(in: "More than 5 franchisees") == nil, "a bare number isn't a date")

        // Kind rules
        let idea = PlannerItem(title: "An idea", kind: .idea)
        idea.toggleDone()
        check(!idea.isDone && !idea.isWork && idea.isResearched, "an idea can't be checked off and isn't work")
        idea.isDone = true; idea.isArchived = true
        check(PlannerKind.migrateContentToPages(in: [idea]) == 1 && !idea.isDone && !idea.isArchived && idea.isIdea,
              "an idea ticked on an old iPhone build is restored, still an idea")

        // Existing items: which get researched, and how many at once
        let schema = Schema([PlannerItem.self, PlannerList.self])
        let container = try ModelContainer(for: schema, configurations:
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = container.mainContext
        let target = cal.date(from: DateComponents(year: 2027, month: 12, day: 31))
        let goalA = PlannerItem(title: "SLOW goal A", notes: "Selective", kind: .goal, date: target)
        let goalB = PlannerItem(title: "SLOW goal B", kind: .goal)
        let goalC = PlannerItem(title: "SLOW goal C", kind: .goal)
        let achieved = PlannerItem(title: "Achieved goal", kind: .goal); achieved.isDone = true
        let linked = PlannerItem(title: "Goal with a page", notes: "Page: https://example.com", kind: .goal)
        let archivedIdea = PlannerItem(title: "Archived idea", kind: .idea); archivedIdea.isArchived = true
        let todo = PlannerItem(title: "A to-do", kind: .task)
        for item in [goalA, goalB, goalC, achieved, linked, archivedIdea, todo] { context.insert(item) }
        try context.save()

        let researcher = ItemResearcher.shared
        researcher.start(container: container)
        check(researcher.running.count == 2, "two run at once")
        check(researcher.status(of: goalC) == .queued, "the third waits")
        check(researcher.status(of: achieved) == nil && researcher.status(of: linked) == nil && researcher.status(of: todo) == nil,
              "achieved goals, items with a page and to-dos have no research status")
        await wait("the goals") { goalA.pageLink != nil && goalB.pageLink != nil && goalC.pageLink != nil }
        check(goalA.pageLink?.hasPrefix("item-pages/") == true && researcher.status(of: goalA) == nil, "the last output line becomes the page link")
        check(goalA.notes.hasPrefix("Selective\nPage:"), "the goal's own notes are kept")
        let researched = Set(calls().map { $0.split(separator: "|")[1] })
        check(calls().count == 3 && researched == ["SLOW goal A", "SLOW goal B", "SLOW goal C"],
              "only the three open goals without a page were researched")
        check(calls().contains { $0.hasPrefix("goal|SLOW goal A|") && $0.contains("target=31 December 2027") && $0.contains("details=Selective") },
              "target date and details reach the script")
        check(calls().first?.contains("goals=SLOW goal A;SLOW goal B;SLOW goal C;Goal with a page") == true, "open goals reach the script as context")

        // Saying an idea
        let before = calls().count
        researcher.add("Sell a tutor add-on", kind: .idea, list: nil, context: context)
        let added = try context.fetch(FetchDescriptor<PlannerItem>()).first { $0.title == "Sell a tutor add-on" }
        check(added?.isIdea == true && added?.date == nil, "add files an undated idea")
        check(added.map { researcher.status(of: $0) == .researching } == true, "research starts straight away")
        await wait("the idea") { added?.pageLink != nil }
        check(added?.pageLink != nil && calls().count == before + 1 && calls().last?.hasPrefix("idea|") == true, "the idea gets its page")

        let goalCount = calls().count
        researcher.add("More than 5 franchisees by 2027", kind: .goal, list: nil, context: context)
        let said = try context.fetch(FetchDescriptor<PlannerItem>()).first { $0.title == "More than 5 franchisees by 2027" }
        check(ymd(said?.date) == [2027, 12, 31], "a said goal takes its target date")
        await wait("the goal") { said?.pageLink != nil }
        check(calls().count == goalCount + 1, "the said goal is researched once")

        // Failure: reported, not retried, until asked
        let failing = PlannerItem(title: "FAIL idea", kind: .idea)
        context.insert(failing)
        researcher.sweep()
        await wait("the failure") { researcher.status(of: failing) == .failed }
        check(researcher.status(of: failing) == .failed && failing.pageLink == nil, "a failed run shows as failed with no link")
        let afterFail = calls().count
        researcher.sweep()
        try await Task.sleep(for: .milliseconds(300))
        check(calls().count == afterFail, "a failed run isn't retried on its own")
        researcher.researchAgain(failing)
        await wait("the retry") { failing.pageLink != nil }
        check(failing.pageLink != nil && calls().last?.contains("force=1") == true, "Research Again forces a new run and links it")

        // Research Again on an item that already has a page replaces the link's run
        let rerun = calls().count
        researcher.researchAgain(goalB)
        await wait("the rerun") { calls().count == rerun + 1 && researcher.running.isEmpty }
        check(calls().last?.contains("force=1") == true && goalB.pageLink != nil, "Research Again works on an item with a page")

        // A page linked while a run was going stays, unless Research Again asked for a new one
        let raced = PlannerItem(title: "SLOW raced idea", kind: .idea)
        context.insert(raced)
        researcher.sweep()
        check(researcher.status(of: raced) == .researching, "the raced idea is running")
        raced.notes = PageLink.notes(raced.notes, setting: "reports/agent-wrote-this.html")
        await wait("the raced run") { researcher.running.isEmpty }
        check(raced.pageLink == "reports/agent-wrote-this.html", "a run doesn't overwrite a page linked meanwhile")
        researcher.researchAgain(raced)
        await wait("the forced run") { raced.pageLink?.hasPrefix("item-pages/") == true }
        check(raced.pageLink?.hasPrefix("item-pages/") == true, "Research Again replaces it")

        // No script (a Mac without the agents)
        defaults.set("/nonexistent/research.sh", forKey: "researchScript")
        let orphan = PlannerItem(title: "No agents here", kind: .idea)
        context.insert(orphan)
        let noScript = calls().count
        researcher.sweep()
        check(researcher.status(of: orphan) == .unavailable && calls().count == noScript, "without the script it says so and doesn't run")

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
