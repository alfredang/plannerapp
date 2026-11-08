// Regression tests for ATO folder parents and the bridge's list name rules: an in-memory store, so
// nothing real is touched or synced.
// Run: xcrun swiftc -D DEBUG -parse-as-library PlannerApp/Models/{PlannerItem,PlannerList,FollowUpActions,PageLink,AppointmentComments}.swift PlannerApp/Services/SmartParser.swift PlannerAppMac/Services/ATOStatus.swift PlannerAppMac/Services/ListNames.swift scripts/test-list-rules.swift -o /tmp/planner-list-rules-tests && /tmp/planner-list-rules-tests
import Foundation
import SwiftData

@main
@MainActor
struct ListRulesTests {
    static var failures = 0

    static func check(_ condition: Bool, _ label: String) {
        print("\(condition ? "PASS" : "FAIL"): \(label)")
        if !condition { failures += 1 }
    }

    static func main() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: PlannerItem.self, PlannerList.self, configurations: config)
        let context = container.mainContext

        func list(_ name: String, under parent: PlannerList? = nil) -> PlannerList {
            let made = PlannerList(name: name, parent: parent)
            context.insert(made)
            return made
        }

        // ATO parents
        let projects = list("Projects")
        let swda = list("SWDA ATO PROJECTS", under: projects)
        let ibf = list("ibf ato projects")
        let old = list("ATO PROJECTS")
        let swdaClient = list("Client A", under: swda)
        let ibfClient = list("Client B", under: ibf)
        let oldClient = list("Client C", under: old)
        let deep = list("Client D records", under: swdaClient)
        let other = list("Client E", under: list("WSQ PROJECTS"))

        check(swdaClient.isATOProject, "client under SWDA ATO PROJECTS counts")
        check(ibfClient.isATOProject, "client under IBF ATO PROJECTS counts, any case")
        check(oldClient.isATOProject, "client under plain ATO PROJECTS still counts")
        check(deep.isATOProject, "a list deeper down counts")
        check(!other.isATOProject, "a list under another parent doesn't")
        check(!swda.isATOProject, "the parent list itself doesn't")

        // The status is by id, so it survives a move between parents.
        let stored = ATOStatus.encode("", setting: .ongoing, for: oldClient)
        check(ATOStatus.of(oldClient, in: stored) == .ongoing, "status reads back")
        oldClient.parent = swda
        check(ATOStatus.of(oldClient, in: stored) == .ongoing, "status survives moving to SWDA ATO PROJECTS")
        oldClient.parent = projects
        check(ATOStatus.of(oldClient, in: stored) == nil, "status isn't shown outside an ATO parent")
        oldClient.parent = old

        // Rename
        let lists = { (try? context.fetch(FetchDescriptor<PlannerList>())) ?? [] }
        check(ListNames.renameError(renaming: projects, to: "client a", in: lists()) != nil,
              "rename onto another list's name is refused, any case")
        check(ListNames.renameError(renaming: projects, to: "PROJECTS", in: lists()) == nil,
              "a list can change the case of its own name")
        check(ListNames.renameError(renaming: projects, to: "Brand new", in: lists()) == nil,
              "rename to a free name is allowed")

        // newlist with parent: the move agents rely on
        check(ListNames.moveError(name: "Client A", parent: "Projects", in: lists()) == nil,
              "moving an existing list is still allowed")
        check(ListNames.moveError(name: "Brand new", parent: "Projects", in: lists()) == nil,
              "a new list under an existing parent is allowed")
        check(ListNames.moveError(name: "Brand new", parent: "New parent", in: lists()) == nil,
              "a new list under a new parent is allowed")

        // Lists already sharing a name
        _ = list("Client A")
        check(ListNames.moveError(name: "Client A", parent: "Projects", in: lists()) != nil,
              "an ambiguous list isn't moved")
        check(ListNames.moveError(name: "Client B", parent: "Client A", in: lists()) != nil,
              "an ambiguous parent isn't used")

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
