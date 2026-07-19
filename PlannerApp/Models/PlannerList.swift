import Foundation
import SwiftData

/// A user-created to-do list (e.g. "Work", "Groceries"). Items may belong to at most one
/// list; deleting a list keeps its items (they fall back to no list).
///
/// CloudKit requirements honoured here (same as `PlannerItem`): every stored property has a
/// default value, there are no unique constraints, and the relationship is optional.
@Model
final class PlannerList {
    var id: UUID = UUID()
    var name: String = ""
    var createdAt: Date = Date()

    /// Manual drag-rearrange position among its siblings, synced via CloudKit so Mac and
    /// iOS agree. 0 (the legacy default) sorts by createdAt among itself.
    var sortOrder: Int = 0

    /// Pinned lists float above their siblings in the sidebar / chip bar (synced).
    var isPinned: Bool = false

    /// The list this one nests under, if any — sub-lists (e.g. a client under "Clients").
    /// Optional (CloudKit requirement). Deleting a parent keeps the children: they move
    /// back to the top level via the nullify inverse below.
    var parent: PlannerList?

    @Relationship(deleteRule: .nullify, inverse: \PlannerList.parent)
    var children: [PlannerList]? = []

    @Relationship(deleteRule: .nullify, inverse: \PlannerItem.list)
    var items: [PlannerItem]? = []

    init(name: String, parent: PlannerList? = nil) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.parent = parent
    }

    /// Active (non-archived) item count, for sidebar/list badges.
    var activeCount: Int {
        (items ?? []).filter { !$0.isArchived }.count
    }

    /// Active items in this list plus all nested sub-lists — parent badges aggregate.
    var subtreeActiveCount: Int {
        activeCount + (children ?? []).reduce(0) { $0 + $1.subtreeActiveCount }
    }

    /// This list's id plus every nested sub-list's id, for filtering items by a parent list.
    var subtreeIDs: Set<UUID> {
        var ids: Set<UUID> = [id]
        for child in children ?? [] { ids.formUnion(child.subtreeIDs) }
        return ids
    }

    /// The person this list belongs to, used to auto-fill "Assign to" for items added inside
    /// someone's list (e.g. "Ryan Ngau (NUS)" → "Ryan").
    ///
    /// A list names a person when it sits **directly under a top-level group** — "Interns ▸
    /// Ryan Ngau (NUS)" or the top-level "Alfred". Deeper lists are that person's own
    /// sub-folders ("Alfred ▸ WSQ Course Conversion"), so they inherit the owner from their
    /// ancestor rather than deriving a nonsense assignee ("WSQ") from their own name.
    var derivedAssignee: String? {
        // If an ancestor already names a person, this is that person's own sub-folder
        // ("Alfred ▸ WSQ Course Conversion") — inherit them rather than deriving a nonsense
        // assignee ("WSQ") from this list's own name.
        if let inherited = parent?.derivedAssignee { return inherited }

        // Top-level *category* lists ("Clients", "Project", "Interns") are not people. The
        // exception is the owner's own list, which legitimately holds sub-folders.
        let owner = UserDefaults.standard.string(forKey: "ownerName") ?? "Alfred"
        if parent == nil, !(children ?? []).isEmpty,
           name.caseInsensitiveCompare(owner) != .orderedSame {
            return nil
        }

        // Drop a trailing "(NUS)" / "(NYP)" style suffix, keep the first name.
        let withoutSuffix = name.replacingOccurrences(
            of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
        let first = withoutSuffix
            .split(separator: " ", omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first, first.count > 1 else { return nil }
        return first
    }

    /// True when `self` sits anywhere below `other` — used to keep drags/moves cycle-free.
    func isDescendant(of other: PlannerList) -> Bool {
        var node = parent
        while let current = node {
            if current.id == other.id { return true }
            node = current.parent
        }
        return false
    }
}

/// One-time repair for items that were captured inside someone's list before the capture
/// bar auto-assigned them — they sit in the right list with an empty "Assign to", so they
/// never show up in that person's queue.
///
/// Only fills **blank** assignees: a name someone typed by hand is never overwritten, and
/// items in category folders ("Interns", "Staff") are left alone since those name no one.
enum AssigneeBackfill {
    /// Only lists under these top-level groups name a real person. "Project" and "Clients"
    /// hold projects and companies (AI-MMS, Innohat, TapCard) whose names are NOT people —
    /// assigning those would push the items out of the owner's own smart views.
    static let peopleGroups = ["Interns", "Staff"]

    /// True when `list` sits under one of the people groups, so its name is someone's name.
    private static func namesAPerson(_ list: PlannerList) -> Bool {
        var node: PlannerList? = list
        while let current = node {
            if peopleGroups.contains(where: { $0.caseInsensitiveCompare(current.name) == .orderedSame }) {
                return true
            }
            node = current.parent
        }
        return false
    }

    /// Returns the items it would change, without mutating anything.
    static func candidates(in items: [PlannerItem]) -> [(item: PlannerItem, owner: String)] {
        items.compactMap { item in
            guard item.assignedTo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let list = item.list,
                  namesAPerson(list),
                  let owner = list.derivedAssignee
            else { return nil }
            return (item, owner)
        }
    }

    /// Key marking that the one-time repair has already run on this device. Bumped to v2:
    /// the v1 pass mutated the items but never saved, so it must run again.
    static let hasRunKey = "assigneeBackfill.hasRun.v2"

    /// Runs the repair once per device, at launch. Fetching from the context directly (and
    /// not a @Query) keeps it independent of which view or scene is on screen.
    static func runOnce(context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: hasRunKey) else { return }
        let items = (try? context.fetch(
            FetchDescriptor<PlannerItem>(predicate: #Predicate { !$0.isArchived }))) ?? []
        let changed = apply(to: items)
        // Persist explicitly: without this the edits stay in memory and are lost on quit.
        // Only mark the pass as done once the save actually succeeded, so a failure retries
        // on the next launch instead of being silently skipped forever.
        if changed > 0 {
            do {
                try context.save()
                log("saved \(changed) assignee change\(changed == 1 ? "" : "s")")
            } catch {
                log("SAVE FAILED: \(error)")
                return
            }
        }
        UserDefaults.standard.set(true, forKey: hasRunKey)
    }

    /// Applies the fill and returns how many items changed.
    @discardableResult
    static func apply(to items: [PlannerItem]) -> Int {
        let work = candidates(in: items)
        for (item, owner) in work { item.assignedTo = owner }
        diagnose(items, work.count)
        return work.count
    }

    /// Appends one line to the Hermes log.
    static func log(_ message: String) {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Planner/Hermes/planner-log.txt")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data("\n\(Date()) [backfill] \(message)\n".utf8))
            try? handle.close()
        }
    }

    /// Writes what the run actually saw to the Hermes log, so a no-op can be explained
    /// instead of guessed at.
    private static func diagnose(_ items: [PlannerItem], _ changed: Int) {
        let blank = items.filter {
            $0.assignedTo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let blankWithList = blank.filter { $0.list != nil }
        let blankNoOwner = blankWithList.filter { $0.list?.derivedAssignee == nil }
        var report = """
        [backfill] items=\(items.count) blank=\(blank.count) \
        blankWithList=\(blankWithList.count) blankButListNamesNoOne=\(blankNoOwner.count) \
        changed=\(changed)
        """
        for item in blankNoOwner.prefix(10) {
            report += "\n  no owner from list “\(item.list?.name ?? "")” — \(item.title.prefix(40))"
        }
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Planner/Hermes/planner-log.txt")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(("\n\(Date()) \(report)\n").utf8))
            try? handle.close()
        }
    }
}
