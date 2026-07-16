import Foundation
import SwiftData

/// Bridge between the embedded Hermes agent terminal and the planner's SwiftData store.
///
/// Hermes is an external CLI agent, so it can't touch SwiftData directly. Instead the app
/// exposes a tiny local protocol inside the agent's workspace folder
/// (`~/Library/Application Support/Planner/Hermes/`):
///
///  * `planner-state.json` — a live snapshot of every list and item, rewritten whenever the
///    data changes, which the agent reads with plain shell tools;
///  * a `planner://` URL command scheme the agent invokes via `open -g "planner://…"` to
///    add / complete / move / rename / reschedule / delete items and manage lists;
///  * `AGENTS.md` — auto-generated instructions that `hermes chat` injects into its system
///    prompt when started in the workspace, teaching it the two mechanisms above;
///  * `planner-log.txt` — the result of each executed command, so the agent can verify.
///
/// Everything stays on this Mac: the bridge is files + a local URL scheme, no network.
enum HermesBridge {

    // MARK: - Workspace

    /// The Hermes working directory. Created on demand.
    static var workspaceURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Planner/Hermes", isDirectory: true)
    }

    private static var stateURL: URL { workspaceURL.appendingPathComponent("planner-state.json") }
    private static var logURL: URL { workspaceURL.appendingPathComponent("planner-log.txt") }
    private static var agentsURL: URL { workspaceURL.appendingPathComponent("AGENTS.md") }

    /// Creates the workspace and (re)writes AGENTS.md so the protocol docs are always current.
    static func prepareWorkspace() {
        try? FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try? agentsInstructions.data(using: .utf8)?.write(to: agentsURL)
    }

    // MARK: - Snapshot

    private struct ItemSnapshot: Codable {
        let id: String
        let title: String
        let kind: String
        let date: String?
        let list: String?
        let notes: String?
        let assignedTo: String?
        let done: Bool
        let archived: Bool
    }

    private struct ListSnapshot: Codable {
        let name: String
        let activeCount: Int
        /// Name of the list this one nests under, when it is a sub-list.
        let parent: String?
    }

    private struct StateSnapshot: Codable {
        let generatedAt: String
        let lists: [ListSnapshot]
        let items: [ItemSnapshot]
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Rewrites `planner-state.json` from the store. Cheap; called on every data change.
    static func writeSnapshot(context: ModelContext) {
        let items = (try? context.fetch(FetchDescriptor<PlannerItem>(
            sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        let lists = (try? context.fetch(FetchDescriptor<PlannerList>(
            sortBy: [SortDescriptor(\.createdAt)]))) ?? []

        let snapshot = StateSnapshot(
            generatedAt: dateFormatter.string(from: Date()),
            lists: lists.map { ListSnapshot(name: $0.name, activeCount: $0.activeCount,
                                            parent: $0.parent?.name) },
            items: items.map { item in
                ItemSnapshot(
                    id: shortID(item.id),
                    title: item.title,
                    kind: item.kind.rawValue,
                    date: item.date.map(dateFormatter.string(from:)),
                    list: item.list?.name,
                    notes: item.notes.isEmpty ? nil : item.notes,
                    assignedTo: item.assignedTo.isEmpty ? nil : item.assignedTo,
                    done: item.isDone,
                    archived: item.isArchived
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try? (try? encoder.encode(snapshot))?.write(to: stateURL)
    }

    private static func shortID(_ id: UUID) -> String {
        String(id.uuidString.lowercased().prefix(8))
    }

    // MARK: - Command handling

    /// Executes one `planner://` command against the store. Returns a human-readable result,
    /// which is also appended to `planner-log.txt` and reflected into a fresh snapshot.
    @discardableResult
    static func handle(_ url: URL, context: ModelContext) -> String {
        let command = url.host ?? url.pathComponents.dropFirst().first ?? ""
        var params: [String: String] = [:]
        for q in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            params[q.name] = q.value ?? ""
        }

        let result = execute(command: command, params: params, context: context)
        try? context.save()
        writeSnapshot(context: context)
        log("\(url.absoluteString) → \(result)")
        return result
    }

    private static func execute(command: String, params: [String: String],
                                context: ModelContext) -> String {
        switch command {
        case "add":
            guard let title = params["title"], !title.isEmpty else { return "ERROR: missing title" }
            let kind: PlannerKind = params["kind"] == "appointment" ? .appointment : .task
            let item = PlannerItem(title: title, notes: params["notes"] ?? "", kind: kind,
                                   date: params["date"].flatMap(parseDate))
            if let listName = params["list"], !listName.isEmpty {
                item.list = findOrCreateList(named: listName, context: context)
            }
            context.insert(item)
            return "OK: added \(kind.rawValue) “\(title)” (id \(shortID(item.id)))"

        case "done", "undone":
            guard let item = findItem(params, context: context) else { return "ERROR: item not found" }
            let target = command == "done"
            if item.isDone != target { item.toggleDone() }
            return "OK: “\(item.title)” marked \(target ? "done (auto-archived)" : "not done (restored)")"

        case "delete":
            guard let item = findItem(params, context: context) else { return "ERROR: item not found" }
            let title = item.title
            context.delete(item)
            return "OK: deleted “\(title)”"

        case "move":
            guard let item = findItem(params, context: context) else { return "ERROR: item not found" }
            let listName = params["list"] ?? ""
            if listName.isEmpty {
                item.list = nil
                return "OK: “\(item.title)” removed from its list"
            }
            item.list = findOrCreateList(named: listName, context: context)
            return "OK: “\(item.title)” moved to \(listName)"

        case "rename":
            guard let item = findItem(params, context: context) else { return "ERROR: item not found" }
            guard let title = params["title"], !title.isEmpty else { return "ERROR: missing title" }
            let old = item.title
            item.title = title
            return "OK: renamed “\(old)” to “\(title)”"

        case "reschedule":
            guard let item = findItem(params, context: context) else { return "ERROR: item not found" }
            if let raw = params["date"], !raw.isEmpty {
                guard let date = parseDate(raw) else { return "ERROR: bad date “\(raw)” — use yyyy-MM-dd HH:mm" }
                item.date = date
                return "OK: “\(item.title)” rescheduled to \(dateFormatter.string(from: date))"
            }
            item.date = nil
            return "OK: cleared the date of “\(item.title)”"

        case "setkind":
            guard let item = findItem(params, context: context) else { return "ERROR: item not found" }
            item.kind = params["kind"] == "appointment" ? .appointment : .task
            return "OK: “\(item.title)” is now a \(item.kind.rawValue)"

        case "note":
            guard let item = findItem(params, context: context) else { return "ERROR: item not found" }
            item.notes = params["notes"] ?? ""
            return "OK: notes of “\(item.title)” updated"

        case "assign":
            guard let item = findItem(params, context: context) else { return "ERROR: item not found" }
            let assignee = params["to"] ?? ""
            item.assignedTo = assignee
            return assignee.isEmpty ? "OK: “\(item.title)” unassigned"
                                    : "OK: “\(item.title)” assigned to \(assignee)"

        case "newlist":
            guard let name = params["name"], !name.isEmpty else { return "ERROR: missing name" }
            let list = findOrCreateList(named: name, context: context)
            // Optional parent=<name>: nest the list as a sub-list (parent created if needed).
            if let parentName = params["parent"], !parentName.isEmpty {
                let parent = findOrCreateList(named: parentName, context: context)
                if parent.id != list.id, !parent.isDescendant(of: list) {
                    list.parent = parent
                }
                return "OK: list “\(name)” exists under “\(parentName)”"
            }
            return "OK: list “\(name)” exists"

        case "deletelist":
            guard let name = params["name"], !name.isEmpty else { return "ERROR: missing name" }
            let lists = (try? context.fetch(FetchDescriptor<PlannerList>())) ?? []
            guard let list = lists.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
            else { return "ERROR: list not found" }
            context.delete(list)   // items are kept — the relationship nullifies
            return "OK: deleted list “\(name)” (its items were kept)"

        default:
            return "ERROR: unknown command “\(command)”"
        }
    }

    // MARK: - Lookup helpers

    /// Finds an item by `id` (the 8-char short id from the snapshot, or a full UUID) or,
    /// failing that, by case-insensitive `title` substring.
    private static func findItem(_ params: [String: String], context: ModelContext) -> PlannerItem? {
        let items = (try? context.fetch(FetchDescriptor<PlannerItem>())) ?? []
        if let ref = params["id"]?.lowercased(), !ref.isEmpty {
            if let hit = items.first(where: { $0.id.uuidString.lowercased().hasPrefix(ref) }) {
                return hit
            }
        }
        if let title = params["title"] ?? params["id"], !title.isEmpty {
            let needle = title.lowercased()
            return items.first { $0.title.lowercased() == needle }
                ?? items.first { $0.title.lowercased().contains(needle) }
        }
        return nil
    }

    private static func findOrCreateList(named name: String, context: ModelContext) -> PlannerList {
        let lists = (try? context.fetch(FetchDescriptor<PlannerList>())) ?? []
        if let hit = lists.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return hit
        }
        let list = PlannerList(name: name)
        context.insert(list)
        return list
    }

    /// Accepts "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd" (local time) and ISO8601.
    private static func parseDate(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            let f = DateFormatter()
            f.dateFormat = format
            f.locale = Locale(identifier: "en_US_POSIX")
            if let d = f.date(from: s) { return d }
        }
        return ISO8601DateFormatter().date(from: s)
    }

    private static func log(_ line: String) {
        let entry = "[\(dateFormatter.string(from: Date()))] \(line)\n"
        guard let data = entry.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }

    // MARK: - Agent instructions

    private static let agentsInstructions = """
    # Planner — Hermes Agent Bridge

    You are running inside the terminal panel of the **Planner** macOS app. Your job is to
    help the user manage their to-dos, appointments and lists conversationally — e.g.
    "add buy milk tomorrow", "move the n8n task to AI-LMS-TMS", "rename X to Y",
    "mark the dentist appointment done", "what's on today?".

    ## Reading the planner

    `planner-state.json` in this directory is a LIVE snapshot of all data (the app rewrites
    it on every change). Read it before answering questions or referencing items:

    ```bash
    cat planner-state.json
    ```

    Each item has a short `id` — always use it when targeting an item. `archived: true`
    items live in the Archive (completed items auto-archive).

    ## Editing the planner

    Execute commands by opening `planner://` URLs with `open -g` (the `-g` keeps focus in
    the terminal). URL-encode spaces as `%20`. Dates are LOCAL time, format `yyyy-MM-dd HH:mm`
    (or just `yyyy-MM-dd`).

    | Action | URL |
    |---|---|
    | Add | `planner://add?title=Buy%20milk&kind=task&date=2026-07-15%2013:00&list=Groceries&notes=2L` |
    | Mark done | `planner://done?id=ab12cd34` |
    | Un-complete / restore | `planner://undone?id=ab12cd34` |
    | Delete | `planner://delete?id=ab12cd34` |
    | Move to a list | `planner://move?id=ab12cd34&list=AI-LMS-TMS` (empty `list=` removes it from its list) |
    | Rename | `planner://rename?id=ab12cd34&title=New%20title` |
    | Reschedule | `planner://reschedule?id=ab12cd34&date=2026-07-16%2009:00` (omit date to clear) |
    | Change kind | `planner://setkind?id=ab12cd34&kind=appointment` (`task` or `appointment`) |
    | Set notes | `planner://note?id=ab12cd34&notes=…` |
    | Assign | `planner://assign?title=Setup%20exams&to=Ngooi` (empty `to` unassigns) |
    | New list | `planner://newlist?name=Errands` (optional `parent=Clients` nests it as a sub-list) |
    | Delete list | `planner://deletelist?name=Errands` (items are kept) |

    Notes:
    * `kind` is `task` (a to-do) or `appointment` (anything at a specific time/place).
    * On `add`, a named `list` is created automatically if it doesn't exist.
    * If you don't know an id you may pass `title=` with a title substring instead — but
      prefer ids from the snapshot; substring matching picks the first match.

    Example:

    ```bash
    open -g "planner://add?title=Lunch%20with%20Sam&kind=appointment&date=2026-07-15%2013:00"
    ```

    ## Verifying

    Every command appends its result to `planner-log.txt` and refreshes the snapshot.
    After each change, confirm it worked:

    ```bash
    tail -1 planner-log.txt && cat planner-state.json
    ```

    Report the outcome to the user briefly and in plain language. If a command returns
    `ERROR:`, read the snapshot again and retry with a correct id.

    ## Ground rules

    * Only manage the planner from here — don't edit `planner-state.json` directly (it is
      overwritten by the app) and don't modify other files on the system unless asked.
    * Resolve relative dates ("tomorrow 3pm") yourself using `date` before building the URL.
    * When the user is ambiguous about which item they mean, show the matching candidates
      and ask.
    """
}
