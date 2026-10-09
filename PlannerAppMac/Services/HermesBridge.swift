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

    /// Whether the agent may **permanently delete** items and lists.
    ///
    /// Defaults to **false**: an agent must never destroy data the user did not explicitly
    /// ask it to. With this off, `delete` archives instead (recoverable from the Archive
    /// view) and `deletelist` is refused outright — deleting a list orphans its items, which
    /// reads to the user as data loss. Toggle it in Settings.
    static let allowsAgentDeletionKey = "hermes.allowsAgentDeletion"

    static var allowsAgentDeletion: Bool {
        UserDefaults.standard.bool(forKey: allowsAgentDeletionKey)   // absent => false
    }

    private static var stateURL: URL { workspaceURL.appendingPathComponent("planner-state.json") }
    private static var logURL: URL { workspaceURL.appendingPathComponent("planner-log.txt") }
    private static var agentsURL: URL { workspaceURL.appendingPathComponent("AGENTS.md") }

    /// The bridge instructions installed as a Hermes skill, so the panel can preload them
    /// with `hermes chat -s planner-app`. AGENTS.md alone is not enough: Hermes only reads
    /// it from its working directory, and a `terminal.cwd` in ~/.hermes/config.yaml (e.g. an
    /// Obsidian vault) overrides the folder the panel launches it in — the agent then never
    /// sees the bridge and files "add an appointment" somewhere else entirely.
    static let hermesSkillName = "planner-app"

    static var hermesSkillURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes/skills/productivity/\(hermesSkillName)/SKILL.md")
    }

    /// Whether Hermes is installed (its home folder exists), i.e. whether the skill applies.
    static var hermesHomeExists: Bool {
        FileManager.default.fileExists(
            atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes").path)
    }

    /// Creates the workspace and (re)writes AGENTS.md — plus the Hermes skill, when Hermes
    /// is installed — so the protocol docs are always current.
    /// The agents' shared long-term memory (see "Shared memory" in AGENTS.md). Created with an
    /// empty index on first run; the contents belong to the agents and are never overwritten.
    static var memoryURL: URL { workspaceURL.appendingPathComponent("memory", isDirectory: true) }

    private static func prepareMemory() {
        let index = memoryURL.appendingPathComponent("MEMORY.md")
        try? FileManager.default.createDirectory(at: memoryURL, withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: index.path) else { return }
        try? "".data(using: .utf8)?.write(to: index)
    }

    static func prepareWorkspace() {
        try? FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try? agentsInstructions.data(using: .utf8)?.write(to: agentsURL)
        prepareMemory()
        // Claude Code reads CLAUDE.md, not AGENTS.md (Codex reads AGENTS.md natively).
        try? "@AGENTS.md\n".data(using: .utf8)?.write(to: workspaceURL.appendingPathComponent("CLAUDE.md"))
        if hermesHomeExists {
            let skill = """
            ---
            name: \(hermesSkillName)
            description: The Planner Mac app — the user's to-dos, APPOINTMENTS, meetings, reminders and lists. Use for any request to add, find, reschedule, complete, move or list tasks or appointments while running in the Planner app's terminal panel.
            ---

            \(agentsInstructions)
            """
            try? FileManager.default.createDirectory(
                at: hermesSkillURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? skill.data(using: .utf8)?.write(to: hermesSkillURL)
        }
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
        /// "critical" / "high" / "medium" / "low" — to-dos only.
        let priority: String?
        /// Video-meeting link of an appointment (kept in its notes).
        let meetingLink: String?
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
            // Sidebar order (parents before their sub-lists), so agents see the current order.
            lists: ListHierarchy.rows(lists).map { row in
                ListSnapshot(name: row.list.name, activeCount: row.list.activeCount,
                             parent: row.list.parent?.name) },
            items: items.map { item in
                ItemSnapshot(
                    id: shortID(item.id),
                    title: item.title,
                    kind: item.kind.rawValue,
                    date: item.date.map(dateFormatter.string(from:)),
                    list: item.list?.name,
                    notes: item.notes.isEmpty ? nil : item.notes,
                    assignedTo: item.assignedTo.isEmpty ? nil : item.assignedTo,
                    priority: item.kind == .task ? item.priority.title.lowercased() : nil,
                    meetingLink: item.meetingLink,
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
        // Decode by hand rather than via URLQueryItem, which leaves `+` as a literal plus.
        // Agents often form-encode spaces as `+` (e.g. Python's urlencode), which used to
        // produce titles like "SMEICC+2026+Opening+Ceremony". A real plus arrives as %2B.
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func decode(_ s: Substring) -> String {
                let spaced = s.replacingOccurrences(of: "+", with: " ")
                return spaced.removingPercentEncoding ?? spaced
            }
            guard let key = parts.first.map(decode), !key.isEmpty else { continue }
            params[key] = parts.count > 1 ? decode(parts[1]) : ""
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
            let kind = parseKind(params["kind"])
            // A date that doesn't parse must fail loudly — silently dropping it filed
            // appointments with no date, which then appear on no calendar day.
            var date: Date?
            if let raw = params["date"], !raw.isEmpty {
                guard let parsed = parseDate(raw) else {
                    return "ERROR: bad date “\(raw)” — use yyyy-MM-dd HH:mm (24-hour, local time); nothing was added"
                }
                date = parsed
            }
            var priority: PlannerPriority?
            if let raw = params["priority"], !raw.isEmpty {
                guard let parsed = PlannerPriority(name: raw) else {
                    return "ERROR: bad priority “\(raw)” — use critical, high, medium or low; nothing was added"
                }
                priority = parsed
            }
            let item = PlannerItem(title: title, notes: params["notes"] ?? "", kind: kind, date: date)
            if let priority, kind == .task { item.setPriority(priority) }
            if let link = params["link"], !link.isEmpty, kind == .appointment {
                item.notes = MeetingLink.notes(item.notes, settingLink: link)
            }
            if let listName = params["list"], !listName.isEmpty {
                item.list = findOrCreateList(named: listName, context: context)
            }
            context.insert(item)
            let when = date.map { " on \(dateFormatter.string(from: $0))" } ?? ""
            return "OK: added \(kind.rawValue) “\(title)”\(when) (id \(shortID(item.id)))"

        case "done", "undone":
            guard let item = findItem(params, context: context) else { return "ERROR: item not found" }
            let target = command == "done"
            if item.isDone != target { item.toggleDone() }
            return "OK: “\(item.title)” marked \(target ? "done (auto-archived)" : "not done (restored)")"

        case "delete":
            guard let item = findItem(params, context: context) else { return "ERROR: item not found" }
            let title = item.title
            // Destructive commands are OFF by default: an agent must never destroy data the
            // user did not explicitly ask it to. Archive instead — recoverable from the
            // Archive view. Enable real deletion in Settings ▸ "Allow agent to delete".
            guard allowsAgentDeletion else {
                if !item.isArchived { item.isArchived = true }
                return "OK: archived “\(title)” (agent deletion is disabled — restore it from Archive, "
                     + "or enable “Allow agent to delete” in Settings)"
            }
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
            item.kind = parseKind(params["kind"])
            return "OK: “\(item.title)” is now a \(item.kind.rawValue)"

        case "note":
            guard let item = findItem(params, context: context) else { return "ERROR: item not found" }
            item.notes = params["notes"] ?? ""
            return "OK: notes of “\(item.title)” updated"

        case "link":
            guard let item = findItem(params, context: context) else { return "ERROR: item not found" }
            guard item.kind == .appointment else { return "ERROR: “\(item.title)” is a to-do — meeting links are for appointments" }
            let link = params["url"] ?? ""
            item.notes = MeetingLink.notes(item.notes, settingLink: link)
            return link.isEmpty ? "OK: removed the meeting link from “\(item.title)”"
                                : "OK: “\(item.title)” meeting link set to \(link)"

        case "priority":
            guard let item = findItem(params, context: context) else { return "ERROR: item not found" }
            guard item.kind == .task else { return "ERROR: “\(item.title)” is an appointment — priority is for to-dos" }
            guard let level = PlannerPriority(name: params["level"] ?? "") else {
                return "ERROR: bad level — use critical, high, medium or low"
            }
            item.setPriority(level)
            let pin = level.autoPins ? " (pinned)" : ""
            return "OK: “\(item.title)” priority set to \(level.title)\(pin)"

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

        case "renamelist":
            guard let name = params["name"], !name.isEmpty else { return "ERROR: missing name" }
            guard let newName = params["to"], !newName.isEmpty else { return "ERROR: missing to" }
            let lists = (try? context.fetch(FetchDescriptor<PlannerList>())) ?? []
            guard let list = lists.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
            else { return "ERROR: list not found" }
            list.name = newName   // non-destructive: items and sub-lists are untouched
            return "OK: renamed list “\(name)” to “\(newName)”"

        case "browse":
            // Opens a page in the agent panel's built-in browser: file=<name> from reports/,
            // or url=<http(s) URL or absolute file path>.
            let target: URL
            if let file = params["file"], !file.isEmpty {
                let url = AgentBrowser.reportsURL.appendingPathComponent(file)
                guard !file.contains(".."), FileManager.default.fileExists(atPath: url.path)
                else { return "ERROR: report “\(file)” not found in \(AgentBrowser.reportsURL.path)" }
                target = url
            } else if let raw = params["url"], !raw.isEmpty {
                if raw.hasPrefix("/") || raw.hasPrefix("~") {
                    let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
                    guard FileManager.default.fileExists(atPath: url.path) else { return "ERROR: file not found" }
                    target = url
                } else {
                    guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "")
                    else { return "ERROR: url must be http(s) or an absolute file path" }
                    target = url
                }
            } else {
                return "ERROR: missing file or url"
            }
            Task { @MainActor in AgentBrowser.shared.open(target) }
            return "OK: opened \(target.isFileURL ? target.lastPathComponent : target.absoluteString) in Planner's browser"

        case "orderlists":
            // names=A,B,C — sibling lists (same parent) in the order wanted. Siblings not
            // named keep their relative order after them. Pinned lists still float first.
            let names = (params["names"] ?? "").split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !names.isEmpty else { return "ERROR: missing names" }
            let lists = (try? context.fetch(FetchDescriptor<PlannerList>())) ?? []
            var ordered: [PlannerList] = []
            for name in names {
                let matches = lists.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                guard let list = matches.first else { return "ERROR: list “\(name)” not found" }
                guard matches.count == 1 else { return "ERROR: more than one list is named “\(name)” — rename one first" }
                guard !ordered.contains(where: { $0.id == list.id }) else { return "ERROR: “\(name)” is named twice" }
                ordered.append(list)
            }
            let parent = ordered[0].parent
            guard ordered.allSatisfy({ $0.parent?.id == parent?.id }) else {
                return "ERROR: orderlists only reorders lists that share the same parent — use separate calls per level"
            }
            let siblings = lists.filter { $0.parent?.id == parent?.id }
            let rest = ManualOrder.sortedPinnedFirst(siblings, pinned: { $0.isPinned },
                                                     position: { $0.sortOrder })
                .filter { list in !ordered.contains { $0.id == list.id } }
            for (index, list) in (ordered + rest).enumerated() { list.sortOrder = index + 1 }
            let pinnedNote = ordered.contains(where: \.isPinned) && ordered.contains(where: { !$0.isPinned })
                ? " (pinned lists still show first)" : ""
            return "OK: ordered " + (ordered + rest).map { "“\($0.name)”" }.joined(separator: ", ")
                 + (parent.map { " under “\($0.name)”" } ?? "") + pinnedNote

        case "deletelist":
            guard let name = params["name"], !name.isEmpty else { return "ERROR: missing name" }
            let lists = (try? context.fetch(FetchDescriptor<PlannerList>())) ?? []
            guard let list = lists.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
            else { return "ERROR: list not found" }
            // Deleting a list orphans every item in it (the relationship nullifies), which
            // reads to the user as "my items vanished". Refuse unless explicitly allowed.
            guard allowsAgentDeletion else {
                let n = list.subtreeActiveCount
                return "REFUSED: agent deletion is disabled, so list “\(name)” was kept"
                     + (n > 0 ? " (it holds \(n) item\(n == 1 ? "" : "s") that would have been orphaned)." : ".")
                     + " Enable “Allow agent to delete” in Settings, or delete the list yourself."
            }
            context.delete(list)   // items are kept — the relationship nullifies
            return "OK: deleted list “\(name)” (its items were kept)"

        default:
            return "ERROR: unknown command “\(command)”"
        }
    }

    // MARK: - Command inbox

    /// The helper script the agent runs (`planner 'add?…'`): it drops the command into
    /// `inbox/` and waits for the app's answer in `outbox/`. Files instead of
    /// `open planner://…` because LaunchServices delivers URLs to the *registered* copy of
    /// the app — with several builds installed that can launch a second, stale Planner
    /// whose writes the visible window never shows — and drops some URLs sent in bursts.
    private static var inboxURL: URL { workspaceURL.appendingPathComponent("inbox", isDirectory: true) }
    private static var outboxURL: URL { workspaceURL.appendingPathComponent("outbox", isDirectory: true) }
    private static var helperURL: URL { workspaceURL.appendingPathComponent("planner") }

    @MainActor private static var inboxSource: DispatchSourceFileSystemObject?
    @MainActor private static var inboxTimer: Timer?
    @MainActor private static var inboxContext: ModelContext?

    private static let helperScript = """
    #!/bin/sh
    # Planner bridge helper (written by the Planner app — edits are overwritten).
    # Sends one command to the running app and prints its result.
    #   planner 'add?title=Lunch with Sam&kind=appointment&date=2026-07-15 13:00'
    # A full planner://… URL works too. Encode a literal & = + % in a value as %26 %3D %2B %25.
    dir="$(cd "$(dirname "$0")" && pwd)"
    if [ $# -lt 1 ]; then
      echo "usage: planner 'add?title=…&kind=appointment&date=yyyy-MM-dd HH:mm'" >&2
      exit 2
    fi
    id="$(date +%s)-$$"
    mkdir -p "$dir/inbox" "$dir/outbox"
    printf '%s' "$*" > "$dir/inbox/.$id.tmp" && mv "$dir/inbox/.$id.tmp" "$dir/inbox/$id.cmd"
    i=0
    while [ $i -lt 50 ]; do
      if [ -f "$dir/outbox/$id.txt" ]; then
        result="$(cat "$dir/outbox/$id.txt")"
        rm -f "$dir/outbox/$id.txt"
        echo "$result"
        case "$result" in ERROR*|REFUSED*) exit 1 ;; esac
        exit 0
      fi
      sleep 0.2
      i=$((i + 1))
    done
    echo "QUEUED: Planner did not answer within 10 s (is the app running?). The command stays queued and runs when Planner opens."
    exit 1

    """

    private static func writeHelperScript() {
        try? FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: outboxURL, withIntermediateDirectories: true)
        try? helperScript.data(using: .utf8)?.write(to: helperURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)
    }

    /// Watches `inbox/` and runs queued commands — immediately on change, plus a slow poll
    /// as a safety net. Also drains anything queued while the app was closed.
    @MainActor
    static func startInbox(context: ModelContext) {
        inboxContext = context
        guard inboxSource == nil else { return }
        writeHelperScript()
        let fd = open(inboxURL.path, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: .write, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { drainInbox() } }
            source.setCancelHandler { close(fd) }
            source.resume()
            inboxSource = source
        }
        let timer = Timer(timeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { drainInbox() }
        }
        RunLoop.main.add(timer, forMode: .common)
        inboxTimer = timer
        drainInbox()
    }

    @MainActor
    private static func drainInbox() {
        guard let context = inboxContext else { return }
        let fm = FileManager.default
        let queued = ((try? fm.contentsOfDirectory(at: inboxURL, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "cmd" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in queued {
            // Claim by atomic rename so two running copies of the app can't both run it.
            let claimed = file.appendingPathExtension("claimed-\(getpid())")
            guard rename(file.path, claimed.path) == 0 else { continue }
            let text = ((try? String(contentsOf: claimed, encoding: .utf8)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try? fm.removeItem(at: claimed)

            let raw = text.hasPrefix("planner://") ? text : "planner://" + text
            let result: String
            if let url = URL(string: raw) ?? URL(string: raw.replacingOccurrences(of: " ", with: "%20")) {
                result = handle(url, context: context)
            } else {
                result = "ERROR: couldn't read the command “\(text)”"
                log("\(text) → \(result)")
            }
            let answer = outboxURL.appendingPathComponent(
                file.deletingPathExtension().lastPathComponent + ".txt")
            try? result.data(using: .utf8)?.write(to: answer, options: .atomic)
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

    /// `appointment` (also "appt", "event", "meeting", any case) or `task` (the default).
    private static func parseKind(_ raw: String?) -> PlannerKind {
        switch raw?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "appointment", "appointments", "appt", "event", "meeting", "calendar":
            return .appointment
        default:
            return .task
        }
    }

    /// Accepts "yyyy-MM-dd HH:mm[:ss]", "yyyy-MM-dd'T'HH:mm[:ss]", "yyyy-MM-dd h:mm a",
    /// "yyyy-MM-dd" (all local time) and ISO8601 with a zone.
    private static func parseDate(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm",
                       "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd h:mm a", "yyyy-MM-dd h:mma", "yyyy-MM-dd"] {
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

    /// The workspace path as written into the instructions.
    private static var workspacePathForDocs: String { workspaceURL.path }

    private static var agentsInstructions: String { """
    # Planner — Hermes Agent Bridge

    You are running inside the terminal panel of the **Planner** macOS app. Your job is to
    help the user manage their to-dos, appointments and lists conversationally — e.g.
    "add buy milk tomorrow", "move the n8n task to AI-LMS-TMS", "rename X to Y",
    "mark the dentist appointment done", "what's on today?".

    **In this panel the Planner app is the source of truth for to-dos and appointments.**
    When the user asks to add, change or look up a task or appointment ("add this to my
    appointments", a screenshot of an invitation, "what's on tomorrow?"), do it in Planner
    with the commands below — not in Obsidian notes, a kanban board or any other file —
    unless the user explicitly names another place.

    Bridge folder (quote it — it contains a space):
    `\(workspacePathForDocs)`

    ## Reading the planner

    `planner-state.json` in the bridge folder is a LIVE snapshot of all data (the app
    rewrites it on every change). Read it before answering questions or referencing items —
    always by its full path, since your working directory may be elsewhere:

    ```bash
    cat "\(workspacePathForDocs)/planner-state.json"
    ```

    Each item has a short `id` — always use it when targeting an item. `archived: true`
    items live in the Archive (completed items auto-archive).

    ## Editing the planner

    Run each command with the bridge helper. It hands the command to the running Planner
    app and prints the result (`OK: …`, or `ERROR: …` with exit status 1):

    ```bash
    "\(workspacePathForDocs)/planner" 'add?title=Lunch with Sam&kind=appointment&date=2026-07-15 13:00'
    ```

    Pass the part of the URLs below after `planner://`. Plain spaces are fine inside the
    single quotes (so are `%20` and `+`); encode a literal `&`, `=`, `+` or `%` in a value
    as `%26`, `%3D`, `%2B`, `%25`. Use the helper — not `open "planner://…"`, which can
    reach the wrong copy of the app and is silently dropped when sent in bursts. Dates are LOCAL time, 24-hour,
    format `yyyy-MM-dd HH:mm` (or just `yyyy-MM-dd` for an all-day item). Anything with a
    specific time or place — meetings, calls, trainings, events, invitations — is
    `kind=appointment`; it then shows in the Appointments view and the Calendar.

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
    | Meeting link (appointments) | `planner://link?id=ab12cd34&url=meet.google.com/abc-defg-hij` (empty `url` removes it; `add` also takes `link=`) |
    | Priority (to-dos) | `planner://priority?id=ab12cd34&level=high` (`critical`, `high`, `medium`, `low`; Critical/High auto-pin) |
    | New list | `planner://newlist?name=Errands` (optional `parent=Clients` nests it as a sub-list) |
    | Rename list | `planner://renamelist?name=Errands&to=Chores` (items and sub-lists are kept) |
    | Reorder lists | `planner://orderlists?names=Alfred,Projects,Clients` — lists sharing one parent (or all top-level), in the order wanted; unnamed siblings follow in their current order. Sub-lists move with their parent. One call per level. |
    | Show a page | `planner://browse?file=2026-10-09-oracle.html` opens a report from `reports/` in Planner's built-in browser (next to this terminal); `planner://browse?url=https://…` opens any web page or absolute file path |
    | Delete list | `planner://deletelist?name=Errands` — **disabled by default, see below** |

    Notes:
    * `kind` is `task` (a to-do) or `appointment` (anything at a specific time/place).
    * On `add`, a named `list` is created automatically if it doesn't exist.
    * On `add`, a to-do may carry `priority=critical|high|medium|low` (default medium).
    * If you don't know an id you may pass `title=` with a title substring instead — but
      prefer ids from the snapshot; substring matching picks the first match.

    ## Shared memory — read first, keep it current

    Every agent that works for this user (Claude Code, Codex, Hermes, OpenClaw and the
    scheduled Digital Workforce agents) shares one long-term memory:
    `\(workspacePathForDocs)/memory/`.

    * **At the start of a session**, read `memory/MEMORY.md` (the index) and open any note
      whose description looks relevant to the request.
    * **Save** anything worth knowing next time: the user's preferences and corrections, decisions
      made, people/clients and who they are, recurring facts, where things live, open
      commitments. One fact per file, e.g. `memory/client-uob.md`:
      ```
      ---
      name: client-uob
      description: UOB — corporate training client; key contacts, programmes, open deals
      metadata:
        type: user | feedback | project | reference
      ---
      The fact. For feedback/project notes add **Why:** and **How to apply:** lines.
      ```
      then add one line to `memory/MEMORY.md`: `- [Title](file.md) — one-line hook`.
    * **Update** an existing note rather than adding a near-duplicate; delete notes that turn
      out to be wrong. Convert relative dates to absolute ones (2026-10-09, not "today").
    * **Never** store passwords, API keys, tokens or other secrets. Don't copy what's already
      in `planner-state.json` (items and lists) — memory is for what the planner can't hold.

    ## Reports (built-in browser)

    Save report pages as self-contained HTML in `reports/` next to this file
    (`reports/<yyyy-MM-dd>-<agent>.html`) and list them newest-first in `reports/index.json`:
    `[{"file":"2026-10-09-oracle.html","title":"Oracle CEO Review","agent":"Oracle","date":"2026-10-09","summary":"one line","url":"https://claude.ai/artifact/… (optional)"}]`.
    Planner's Browser tab lists them automatically; use `browse` to bring one up.

    ## Verifying

    The helper prints each command's result, and the snapshot is refreshed right after —
    re-read it when you need the new state. If the helper prints `QUEUED:`, Planner isn't
    running: the command waits and runs when the app opens — tell the user. Every result
    is also appended to `planner-log.txt`.

    Report the outcome to the user briefly and in plain language. If a command returns
    `ERROR:`, read the snapshot again and retry with a correct id.

    ## Ground rules

    * **NEVER delete anything the user did not explicitly ask you to delete.** Deletion is
      disabled by default: `delete` archives the item instead, and `deletelist` is refused.
      This is deliberate — do not try to work around it.
    * **Never delete-and-recreate a list to reorganise it.** Deleting a list orphans every
      item inside it, and the user experiences that as "my items disappeared". To restructure,
      use `newlist` (with `parent=`) and `move` only — both are non-destructive.
    * When a request would remove data ("clean up", "reset", "start fresh", "tidy the lists"),
      do NOT infer permission to delete. Say what you would remove and ask the user first.
    * Only manage the planner from here — don't edit `planner-state.json` directly (it is
      overwritten by the app) and don't modify other files on the system unless asked.
    * Resolve relative dates ("tomorrow 3pm") yourself using `date` before building the URL.
    * When the user is ambiguous about which item they mean, show the matching candidates
      and ask.
    """
    }
}
