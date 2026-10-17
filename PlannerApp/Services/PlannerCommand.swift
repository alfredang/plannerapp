import Foundation
import SwiftData
#if canImport(FoundationModels)
import FoundationModels
#endif

/// What the user asked the assistant to do. The on-device model picks the action and names
/// the target; **all mutation happens in deterministic code** (`PlannerCommand.run`), so the
/// model can never invent a date, delete something unasked, or edit a field it wasn't given.
///
/// This is the iPhone counterpart to the Mac's Hermes bridge: same verbs, no terminal and no
/// external agent — Apple's on-device FoundationModels does the intent parsing locally.
enum PlannerAction: String, CaseIterable {
    case add            // "buy milk tomorrow"
    case complete       // "mark the dentist appointment done"
    case uncomplete     // "un-check the ATO task"
    case reschedule     // "move standup to Friday 9am"
    case clearDate      // "remove the date from X"
    case move           // "put the n8n task in Ryan's list"
    case assign         // "assign the VPS task to Ryan"
    case rename         // "rename X to Y"
    case note           // "add a note to X: ..."
    case setKind        // "make X an appointment"
    case delete         // "delete X" — ARCHIVES, never destroys (see run)
    case pin            // "pin X" / "unpin X"
    case reorder        // "move X to the top"
    case newList        // "create a list called Errands"
    case renameList     // "rename the Clients list to Accounts"
    case unknown        // anything else — answered conversationally, nothing changes

    /// Actions that edit one existing item, named by `target`.
    var targetsItem: Bool { ![.add, .unknown, .newList, .renameList].contains(self) }
}

/// The outcome of running a command: what to say, and the item it touched (if any).
struct CommandResult {
    var reply: String
    var item: PlannerItem?
    /// True when the store was modified — the caller re-arms reminders / calendar sync.
    var didMutate: Bool
    /// What was actually done (an edit the model misread falls back to `.add`).
    var action: PlannerAction = .add
}

enum PlannerCommand {

    /// Interpret `text` and carry it out. Never throws; anything unparseable falls back to
    /// "add", which is the overwhelmingly common intent and is always safe (it only creates).
    /// `defaultList` is where a plain add lands when the user didn't name a list — the
    /// capture bar passes the list that is open on screen.
    @MainActor
    static func handle(_ text: String, context: ModelContext, ownerName: String,
                       defaultList: PlannerList? = nil) async -> CommandResult {
        let active = (try? context.fetch(
            FetchDescriptor<PlannerItem>(predicate: #Predicate { !$0.isArchived }))) ?? []
        let lists = (try? context.fetch(FetchDescriptor<PlannerList>())) ?? []

        var parsed = await classify(text, items: active, lists: lists)

        // An edit must clearly name an existing item. When it doesn't, the user was most
        // likely describing something new — "Update the website by Friday", or a fresh
        // entry the model misread as an edit — so add it rather than drop their words or
        // move an unrelated item that shares one word with it. Verbs like "mark … done"
        // or "delete …" make no sense as a new item, so those still answer "couldn't find".
        if parsed.action.targetsItem,
           parsed.action == .reschedule || (parsed.fromModel && !startsWithEditVerb(text)),
           matchItem(parsed.target,
                     in: parsed.action == .uncomplete ? allItems(context) : active,
                     confident: true) == nil {
            parsed.action = .add
        }

        var result = await run(parsed, text: text, context: context,
                               active: active, lists: lists, defaultList: defaultList)
        result.action = parsed.action == .unknown ? .add : parsed.action
        return result
    }

    /// Follow-through after `handle` changed something: mirror the item to Calendar, SAVE
    /// right away — that is what hands the change to iCloud, so the other devices see it
    /// without waiting on autosave (which never runs if the phone is locked straight after
    /// dictating) — and re-arm the alerts for the new date.
    @MainActor
    static func commit(_ result: CommandResult, context: ModelContext) async {
        guard result.didMutate else { return }
        if let item = result.item, let id = CalendarSync.sync(item) { item.calendarEventID = id }
        try? context.save()
        await ReminderScheduler.rescheduleAll(context: context)
    }

    @MainActor
    private static func run(_ parsed: ParsedCommand, text: String, context: ModelContext,
                            active: [PlannerItem], lists: [PlannerList],
                            defaultList: PlannerList?) async -> CommandResult {
        switch parsed.action {
        case .add, .unknown:
            let draft = await IntentAssistant.draft(from: text)
            guard !draft.entry.title.isEmpty else {
                return CommandResult(reply: draft.reply, item: nil, didMutate: false)
            }
            let item = draft.entry.makeItem()
            // Adding while a list is named (or open) files it there and inherits that
            // list's owner.
            if let list = matchList(parsed.listName, in: lists) ?? defaultList {
                item.list = list
                if let owner = list.derivedAssignee { item.assignedTo = owner }
            }
            context.insert(item)
            return CommandResult(reply: draft.reply, item: item, didMutate: true)

        case .complete:
            guard let item = matchItem(parsed.target, in: active) else {
                return miss(parsed.target)
            }
            if !item.isDone { item.toggleDone() }
            return CommandResult(reply: "Marked “\(item.title)” done — it's in the Archive now.",
                                 item: item, didMutate: true)

        case .reschedule:
            guard let item = matchItem(parsed.target, in: active) else {
                return miss(parsed.target)
            }
            // Dates ALWAYS come from the deterministic parser, never the model.
            guard let (date, hasTime) = newDate(for: item, from: text, target: parsed.target) else {
                return CommandResult(
                    reply: "I couldn't read a date in that. Try “move \(item.title) to Friday 9am”.",
                    item: item, didMutate: false)
            }
            item.date = date
            // A clock time makes it an appointment; a new deadline day keeps a to-do a to-do.
            if item.kind == .task, hasTime { item.kind = .appointment }
            let when = date.formatted(.dateTime.weekday().month().day().hour().minute())
            return CommandResult(reply: "Moved “\(item.title)” to \(when).",
                                 item: item, didMutate: true)

        case .move:
            guard let item = matchItem(parsed.target, in: active) else { return miss(parsed.target) }
            guard let list = matchList(parsed.listName, in: lists) else {
                return CommandResult(reply: "I couldn't find a list called “\(parsed.listName)”.",
                                     item: item, didMutate: false)
            }
            item.list = list
            if let owner = list.derivedAssignee { item.assignedTo = owner }
            return CommandResult(reply: "Moved “\(item.title)” to \(list.name).",
                                 item: item, didMutate: true)

        case .assign:
            guard let item = matchItem(parsed.target, in: active) else { return miss(parsed.target) }
            let who = parsed.assignee.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !who.isEmpty else {
                return CommandResult(reply: "Who should I assign that to?", item: item, didMutate: false)
            }
            item.assignedTo = who
            return CommandResult(reply: "Assigned “\(item.title)” to \(who).",
                                 item: item, didMutate: true)

        case .rename:
            guard let item = matchItem(parsed.target, in: active) else { return miss(parsed.target) }
            let newTitle = parsed.newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newTitle.isEmpty else {
                return CommandResult(reply: "What should I rename it to?", item: item, didMutate: false)
            }
            let old = item.title
            item.title = newTitle
            return CommandResult(reply: "Renamed “\(old)” to “\(newTitle)”.",
                                 item: item, didMutate: true)

        case .uncomplete:
            guard let item = matchItem(parsed.target, in: allItems(context)) else {
                return miss(parsed.target)
            }
            if item.isDone { item.toggleDone() }
            return CommandResult(reply: "Restored “\(item.title)” — it's back in your list.",
                                 item: item, didMutate: true)

        case .clearDate:
            guard let item = matchItem(parsed.target, in: active) else { return miss(parsed.target) }
            item.date = nil
            // An appointment with no date is meaningless; it becomes a to-do.
            if item.kind == .appointment { item.kind = .task }
            return CommandResult(reply: "Cleared the date on “\(item.title)” — it's a to-do now.",
                                 item: item, didMutate: true)

        case .note:
            guard let item = matchItem(parsed.target, in: active) else { return miss(parsed.target) }
            item.notes = parsed.notes
            return CommandResult(reply: parsed.notes.isEmpty
                                 ? "Cleared the notes on “\(item.title)”."
                                 : "Added a note to “\(item.title)”.",
                                 item: item, didMutate: true)

        case .setKind:
            guard let item = matchItem(parsed.target, in: active) else { return miss(parsed.target) }
            let wantsAppointment = parsed.kind.lowercased().contains("appointment")
            item.kind = wantsAppointment ? .appointment : .task
            if wantsAppointment, item.date == nil, let d = SmartParser.parse(text).date {
                item.date = d
            }
            return CommandResult(reply: "“\(item.title)” is now a \(item.kind.title).",
                                 item: item, didMutate: true)

        case .delete:
            guard let item = matchItem(parsed.target, in: active) else { return miss(parsed.target) }
            // NEVER destroys: archiving keeps the item fully recoverable from the Archive
            // view. An assistant must not be able to lose your data on a mis-parse.
            item.isArchived = true
            return CommandResult(
                reply: "Archived “\(item.title)”. It's out of your lists but still in the Archive if you need it back.",
                item: item, didMutate: true)

        case .pin:
            guard let item = matchItem(parsed.target, in: active) else { return miss(parsed.target) }
            // "unpin" is explicit; anything else pins.
            let wantsUnpin = text.lowercased().contains("unpin")
                || text.lowercased().contains("un-pin")
            item.isPinned = !wantsUnpin
            return CommandResult(reply: item.isPinned
                                 ? "Pinned “\(item.title)” to the top."
                                 : "Unpinned “\(item.title)”.",
                                 item: item, didMutate: true)

        case .reorder:
            guard let item = matchItem(parsed.target, in: active) else { return miss(parsed.target) }
            let toBottom = text.lowercased().contains("bottom")
                || text.lowercased().contains("end")
                || text.lowercased().contains("last")
            // Peers are the rows this item actually sits among, so the new position is
            // meaningful in the view the user is looking at.
            let peers = active.filter { $0.kind == item.kind && $0.list?.id == item.list?.id }
            let positions = peers.map(\.sortOrder)
            if toBottom {
                item.sortOrder = (positions.max() ?? 0) + 1
            } else {
                item.sortOrder = (positions.min() ?? 1) - 1
            }
            return CommandResult(reply: toBottom
                                 ? "Moved “\(item.title)” to the bottom."
                                 : "Moved “\(item.title)” to the top.",
                                 item: item, didMutate: true)

        case .newList:
            let name = parsed.listName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                return CommandResult(reply: "What should the list be called?", item: nil, didMutate: false)
            }
            if let existing = matchList(name, in: lists) {
                return CommandResult(reply: "“\(existing.name)” already exists.",
                                     item: nil, didMutate: false)
            }
            let parent = matchList(parsed.parentList, in: lists)
            context.insert(PlannerList(name: name, parent: parent))
            return CommandResult(reply: parent == nil
                                 ? "Created the list “\(name)”."
                                 : "Created “\(name)” under “\(parent!.name)”.",
                                 item: nil, didMutate: true)

        case .renameList:
            guard let list = matchList(parsed.listName, in: lists) else {
                return CommandResult(reply: "I couldn't find a list called “\(parsed.listName)”.",
                                     item: nil, didMutate: false)
            }
            let newName = parsed.newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty else {
                return CommandResult(reply: "What should I rename the list to?", item: nil, didMutate: false)
            }
            let old = list.name
            list.name = newName          // non-destructive: items and sub-lists are kept
            return CommandResult(reply: "Renamed the list “\(old)” to “\(newName)”.",
                                 item: nil, didMutate: true)
        }
    }

    /// The new slot for `item`. "to 8pm" keeps the item's day; "to Friday" keeps its time.
    /// The date is read from the words around the title, so a time inside the title itself
    /// ("Exam (7:30pm–9:45pm)") isn't mistaken for the new slot.
    static func newDate(for item: PlannerItem, from text: String,
                        target: String) -> (date: Date, hasTime: Bool)? {
        var phrase = text
        if !target.isEmpty, let r = phrase.range(of: target, options: .caseInsensitive) {
            phrase.replaceSubrange(r, with: " ")
        }
        guard let when = SmartParser.when(in: phrase) ?? SmartParser.when(in: text) else { return nil }
        let cal = Calendar.current
        guard let old = item.date else { return (when.date, when.hasTime) }
        if when.hasTime, !when.hasDay {
            let t = cal.dateComponents([.hour, .minute], from: when.date)
            guard let d = cal.date(bySettingHour: t.hour ?? 0, minute: t.minute ?? 0,
                                   second: 0, of: old) else { return nil }
            return (d, true)
        }
        if when.hasDay, !when.hasTime {
            let t = cal.dateComponents([.hour, .minute], from: old)
            guard let d = cal.date(bySettingHour: t.hour ?? 0, minute: t.minute ?? 0,
                                   second: 0, of: when.date) else { return nil }
            return (d, t.hour != 0 || t.minute != 0)
        }
        return (when.date, when.hasTime)
    }

    /// Leading words that make an utterance unmistakably an edit of an existing item.
    private static let editVerbs: Set<String> = [
        "mark", "complete", "move", "reschedule", "change", "update", "shift", "postpone",
        "push", "bring", "rename", "assign", "delete", "remove", "archive", "pin", "unpin",
        "restore", "uncheck", "put", "cancel"
    ]

    static func startsWithEditVerb(_ text: String) -> Bool {
        let first = text.lowercased().split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? ""
        return editVerbs.contains(first)
    }

    /// Every item including archived ones — needed to restore something already checked off.
    @MainActor
    private static func allItems(_ context: ModelContext) -> [PlannerItem] {
        (try? context.fetch(FetchDescriptor<PlannerItem>())) ?? []
    }

    private static func miss(_ target: String) -> CommandResult {
        CommandResult(reply: "I couldn't find “\(target)”. Try naming it as it appears in your list.",
                      item: nil, didMutate: false)
    }

    // MARK: - Matching (deterministic)

    /// Find the item the user meant: exact title first, then a contains match, then the
    /// best word-overlap score. Returns nil rather than guessing when nothing is close.
    /// `confident` additionally requires the overlap to cover at least half the words named.
    static func matchItem(_ target: String, in items: [PlannerItem],
                          confident: Bool = false) -> PlannerItem? {
        let needle = target.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        if let exact = items.first(where: { $0.title.lowercased() == needle }) { return exact }
        if let contains = items.first(where: { $0.title.lowercased().contains(needle) }) { return contains }

        let terms = Set(needle.split(whereSeparator: \.isWhitespace).map(String.init))
        guard !terms.isEmpty else { return nil }
        let scored = items
            .map { item -> (PlannerItem, Int) in
                let words = Set(item.title.lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
                return (item, terms.intersection(words).count)
            }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
        guard let best = scored.first else { return nil }
        if confident, best.1 * 2 < terms.count { return nil }
        return best.0
    }

    static func matchList(_ name: String, in lists: [PlannerList]) -> PlannerList? {
        let needle = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        if let exact = lists.first(where: { $0.name.lowercased() == needle }) { return exact }
        return lists.first { $0.name.lowercased().contains(needle) }
    }

    // MARK: - Intent classification (on-device Apple Intelligence)

    struct ParsedCommand {
        var action: PlannerAction = .add
        var target: String = ""
        var listName: String = ""
        var assignee: String = ""
        var newTitle: String = ""
        var notes: String = ""
        var kind: String = ""
        var parentList: String = ""
        /// Classified by Apple Intelligence (vs. the keyword rules).
        var fromModel = false
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    @Generable
    fileprivate struct CommandDraft {
        @Guide(description: "One of: add, complete, uncomplete, reschedule, clearDate, move, assign, rename, note, setKind, delete, pin, reorder, newList, renameList. Use \"add\" when the user is describing something new to do.")
        var action: String

        @Guide(description: "For anything other than add/newList: the existing item's title, copied from the user's words. Empty for add.")
        var target: String

        @Guide(description: "The list name, if the user named one (also the new list's name for newList, and the list being renamed for renameList). Otherwise empty.")
        var listName: String

        @Guide(description: "The person's name, if the user is assigning to someone. Otherwise empty.")
        var assignee: String

        @Guide(description: "The new title, for a rename or renameList. Otherwise empty.")
        var newTitle: String

        @Guide(description: "The note text, only when the user is setting notes on an item. Otherwise empty.")
        var notes: String

        @Guide(description: "\"task\" or \"appointment\", only when the user is changing an item's type. Otherwise empty.")
        var kind: String

        @Guide(description: "The parent list, only when creating a sub-list under another list. Otherwise empty.")
        var parentList: String
    }
    #endif

    /// Classify the utterance. Falls back to keyword rules when Apple Intelligence is
    /// unavailable, so the feature works on every supported device.
    static func classify(_ text: String,
                         items: [PlannerItem],
                         lists: [PlannerList]) async -> ParsedCommand {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *),
           case .available = SystemLanguageModel.default.availability {
            let session = LanguageModelSession(instructions: """
                You route planner requests to one action. Choose "add" when the user \
                describes something new to do. Choose "complete", "reschedule", "move", \
                "assign" or "rename" only when they clearly refer to an item that already \
                exists. Choose "reschedule" when they change the date or time of an existing \
                item — "change", "update", "move", "shift", "postpone", "push back", \
                "bring forward", "is now at", "instead". For target, copy the existing item's \
                title from the list when the request clearly refers to one; otherwise copy \
                the user's own words — never invent them. Never guess a date; the app \
                parses dates separately.
                """)
            // The items it may refer to — upcoming ones first, since edits are mostly
            // about what's coming up.
            let startOfToday = Calendar.current.startOfDay(for: Date())
            let known = items
                .sorted { a, b in
                    let ka = a.date.map { $0 >= startOfToday ? 0 : 1 } ?? 2
                    let kb = b.date.map { $0 >= startOfToday ? 0 : 1 } ?? 2
                    if ka != kb { return ka < kb }
                    return (a.date ?? .distantFuture) < (b.date ?? .distantFuture)
                }
                .prefix(60)
                .map { "- \($0.title)" }
                .joined(separator: "\n")
            let prompt = known.isEmpty
                ? "Request: \"\(text)\""
                : "Existing items:\n\(known)\n\nRequest: \"\(text)\""
            if let response = try? await session.respond(to: prompt,
                                                         generating: CommandDraft.self) {
                let d = response.content
                // Match the raw value case-insensitively ("setkind" → .setKind).
                let action = PlannerAction.allCases.first {
                    $0.rawValue.lowercased() == d.action.lowercased()
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } ?? .add
                return ParsedCommand(
                    action: action,
                    target: d.target, listName: d.listName,
                    assignee: d.assignee, newTitle: d.newTitle,
                    notes: d.notes, kind: d.kind, parentList: d.parentList,
                    fromModel: true)
            }
        }
        #endif
        return keywordFallback(text)
    }

    /// Deterministic fallback: leading verb decides the action. Deliberately conservative —
    /// anything ambiguous becomes `.add`, which can only create.
    static func keywordFallback(_ text: String) -> ParsedCommand {
        let lower = text.lowercased()
        func after(_ markers: [String]) -> String {
            for m in markers {
                if let r = lower.range(of: m) {
                    return String(text[r.upperBound...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            return ""
        }
        if lower.hasPrefix("mark ") || lower.contains(" done") || lower.hasPrefix("complete ") {
            var t = after(["mark ", "complete "])
            for suffix in [" as done", " done", " as complete", " complete"] {
                if t.lowercased().hasSuffix(suffix) { t = String(t.dropLast(suffix.count)) }
            }
            return ParsedCommand(action: .complete, target: t)
        }
        if lower.hasPrefix("rename ") {
            let rest = after(["rename "])
            let parts = rest.components(separatedBy: " to ")
            return ParsedCommand(action: .rename,
                                 target: parts.first?.trimmingCharacters(in: .whitespaces) ?? "",
                                 newTitle: parts.count > 1 ? parts[1] : "")
        }
        if lower.hasPrefix("assign ") {
            let rest = after(["assign "])
            let parts = rest.components(separatedBy: " to ")
            return ParsedCommand(action: .assign,
                                 target: parts.first?.trimmingCharacters(in: .whitespaces) ?? "",
                                 assignee: parts.count > 1 ? parts[1] : "")
        }
        // "change X to 8pm", "postpone X to Friday", "push back X to 3pm", "update X to Y".
        for verb in ["change ", "update ", "shift ", "postpone ", "push back ", "push ",
                     "bring forward ", "bring ", "reschedule "] where lower.hasPrefix(verb) {
            var rest = String(text.dropFirst(verb.count))
            for filler in ["the ", "my "] where rest.lowercased().hasPrefix(filler) {
                rest = String(rest.dropFirst(filler.count))
            }
            let restLower = rest.lowercased()
            let cut = [" to ", " at ", " on ", " till ", " until ", " for ", " from "]
                .compactMap { restLower.range(of: $0)?.lowerBound }
                .min()
            let target = (cut.map { String(rest[..<$0]) } ?? rest)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if SmartParser.when(in: rest) != nil || verb == "reschedule " || verb.hasPrefix("postpone")
                || verb.hasPrefix("push") || verb.hasPrefix("bring") || verb.hasPrefix("shift") {
                return ParsedCommand(action: .reschedule, target: target)
            }
            // "change X to Y" with no date in it is a rename.
            let parts = rest.components(separatedBy: " to ")
            if parts.count > 1 {
                return ParsedCommand(action: .rename,
                                     target: parts[0].trimmingCharacters(in: .whitespaces),
                                     newTitle: parts.dropFirst().joined(separator: " to "))
            }
            return ParsedCommand(action: .reschedule, target: target)
        }
        if lower.hasPrefix("move ") || lower.hasPrefix("put ") {
            let rest = after(["move ", "put "])
            let parts = rest.components(separatedBy: [" to ", " in "].first { rest.lowercased().contains($0) } ?? " to ")
            let target = parts.first?.trimmingCharacters(in: .whitespaces) ?? ""
            let dest = parts.count > 1 ? parts[1] : ""
            // "move X to Friday" is a reschedule; "move X to Ryan's list" is a move.
            if SmartParser.parse(rest).date != nil {
                return ParsedCommand(action: .reschedule, target: target)
            }
            return ParsedCommand(action: .move, target: target, listName: dest)
        }
        if lower.hasPrefix("delete ") || lower.hasPrefix("remove ") || lower.hasPrefix("archive ") {
            return ParsedCommand(action: .delete, target: after(["delete ", "remove ", "archive "]))
        }
        if lower.hasPrefix("pin ") || lower.hasPrefix("unpin ") || lower.hasPrefix("un-pin ") {
            return ParsedCommand(action: .pin, target: after(["unpin ", "un-pin ", "pin "]))
        }
        if lower.contains("to the top") || lower.contains("to the bottom") {
            var t = after(["move ", "put ", "reorder "])
            for suffix in [" to the top", " to the bottom"] {
                if let r = t.lowercased().range(of: suffix) { t = String(t[..<r.lowerBound]) }
            }
            return ParsedCommand(action: .reorder,
                                 target: t.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if lower.hasPrefix("restore ") || lower.hasPrefix("uncheck ") || lower.hasPrefix("un-check ") {
            return ParsedCommand(action: .uncomplete,
                                 target: after(["restore ", "uncheck ", "un-check "]))
        }
        if lower.hasPrefix("create a list") || lower.hasPrefix("new list")
            || lower.hasPrefix("create list") || lower.hasPrefix("add a list") {
            var name = after(["create a list called ", "create a list ", "new list called ",
                              "new list ", "create list ", "add a list called ", "add a list "])
            var parent = ""
            if let r = name.lowercased().range(of: " under ") {
                parent = String(name[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                name = String(name[..<r.lowerBound])
            }
            return ParsedCommand(action: .newList,
                                 listName: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                 parentList: parent)
        }
        if lower.contains("make ") && (lower.contains("an appointment") || lower.contains("a to-do")
                                       || lower.contains("a task")) {
            var t = after(["make "])
            for suffix in [" an appointment", " a to-do", " a todo", " a task"] {
                if let r = t.lowercased().range(of: suffix) { t = String(t[..<r.lowerBound]) }
            }
            return ParsedCommand(action: .setKind,
                                 target: t.trimmingCharacters(in: .whitespacesAndNewlines),
                                 kind: lower.contains("appointment") ? "appointment" : "task")
        }
        return ParsedCommand(action: .add)
    }
}
