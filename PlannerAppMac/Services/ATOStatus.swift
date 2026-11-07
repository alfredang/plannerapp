import SwiftUI

/// Where a client's ATO application stands, shown as the colour of its folder under the
/// "ATO PROJECTS" list: successful is green, ongoing is brown, rejected is red. A folder with no
/// status is the plain one, so an unconfirmed outcome is never shown as a result.
///
/// Kept per Mac, by list id so a rename keeps it: the iPhone has no such folders, and a CloudKit
/// field isn't worth a schema change for a colour. Set from the folder's menu, or by an agent
/// with `planner://atostatus`. Client names stay out of the code: this repo is public.
enum ATOStatus: String, CaseIterable, Identifiable {
    case successful, ongoing, rejected

    /// The parent list whose sub-lists are ATO applications.
    static let parentListName = "ATO PROJECTS"
    /// `@AppStorage` key: JSON of list id → raw status.
    static let storageKey = "atoProjectStatus"

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var color: Color {
        switch self {
        // The same three as the All ATO Projects board page.
        case .successful: return Color(red: 0x2E / 255, green: 0x9E / 255, blue: 0x5B / 255)
        case .ongoing:    return Color(red: 0x8B / 255, green: 0x5A / 255, blue: 0x2B / 255)
        case .rejected:   return Color(red: 0xD1 / 255, green: 0x3B / 255, blue: 0x2E / 255)
        }
    }

    static func decode(_ stored: String) -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(stored.utf8))) ?? [:]
    }

    /// The stored text with `list`'s status set, or cleared when `status` is `nil`.
    static func encode(_ stored: String, setting status: ATOStatus?, for list: PlannerList) -> String {
        var map = decode(stored)
        map[list.id.uuidString] = status?.rawValue
        guard let data = try? JSONEncoder().encode(map) else { return stored }
        return String(decoding: data, as: UTF8.self)
    }

    /// `list`'s status in the stored text. Only an ATO project has one.
    static func of(_ list: PlannerList, in stored: String) -> ATOStatus? {
        guard list.isATOProject else { return nil }
        return decode(stored)[list.id.uuidString].flatMap(ATOStatus.init(rawValue:))
    }
}

extension PlannerList {
    /// Inside the "ATO PROJECTS" list, at any depth.
    var isATOProject: Bool {
        var node = parent
        while let current = node {
            if current.name.caseInsensitiveCompare(ATOStatus.parentListName) == .orderedSame { return true }
            node = current.parent
        }
        return false
    }
}
