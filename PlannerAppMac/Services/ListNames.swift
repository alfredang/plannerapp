import Foundation

/// Name rules for the agent bridge, which finds lists by name across the whole sidebar, ignoring
/// case. Two lists with one name make every such lookup a guess.
enum ListNames {
    static func matching(_ name: String, in lists: [PlannerList]) -> [PlannerList] {
        lists.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Why `list` can't take `newName`, or `nil` if it can. Changing only the case of its own name
    /// is allowed.
    static func renameError(renaming list: PlannerList, to newName: String, in lists: [PlannerList]) -> String? {
        guard matching(newName, in: lists).contains(where: { $0.id != list.id }) else { return nil }
        return "a list named “\(newName)” already exists — pick another name"
    }

    /// Why `newlist?name=…&parent=…` can't tell which lists it means, or `nil` if it can. A name
    /// that doesn't exist yet is fine: that list gets created.
    static func moveError(name: String, parent: String, in lists: [PlannerList]) -> String? {
        for candidate in [name, parent] where matching(candidate, in: lists).count > 1 {
            return "more than one list is named “\(candidate)” — rename one first"
        }
        return nil
    }
}
