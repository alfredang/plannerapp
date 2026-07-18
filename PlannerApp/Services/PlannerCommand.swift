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
    case reschedule     // "move standup to Friday 9am"
    case move           // "put the n8n task in Ryan's list"
    case assign         // "assign the VPS task to Ryan"
    case rename         // "rename X to Y"
    case unknown        // anything else — answered conversationally, nothing changes
}

/// The outcome of running a command: what to say, and the item it touched (if any).
struct CommandResult {
    var reply: String
    var item: PlannerItem?
    /// True when the store was modified — the caller re-arms reminders / calendar sync.
    var didMutate: Bool
}

enum PlannerCommand {

    /// Interpret `text` and carry it out. Never throws; anything unparseable falls back to
    /// "add", which is the overwhelmingly common intent and is always safe (it only creates).
    @MainActor
    static func handle(_ text: String, context: ModelContext, ownerName: String) async -> CommandResult {
        let active = (try? context.fetch(
            FetchDescriptor<PlannerItem>(predicate: #Predicate { !$0.isArchived }))) ?? []
        let lists = (try? context.fetch(FetchDescriptor<PlannerList>())) ?? []

        let parsed = await classify(text, items: active, lists: lists)

        switch parsed.action {
        case .add, .unknown:
            let draft = await IntentAssistant.draft(from: text)
            guard !draft.entry.title.isEmpty else {
                return CommandResult(reply: draft.reply, item: nil, didMutate: false)
            }
            let item = draft.entry.makeItem()
            // Adding while a list is named files it there and inherits that list's owner.
            if let list = matchList(parsed.listName, in: lists) {
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
            guard let date = SmartParser.parse(text).date else {
                return CommandResult(
                    reply: "I couldn't read a date in that. Try “move \(item.title) to Friday 9am”.",
                    item: item, didMutate: false)
            }
            item.date = date
            if item.kind == .task { item.kind = .appointment }
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
        }
    }

    private static func miss(_ target: String) -> CommandResult {
        CommandResult(reply: "I couldn't find “\(target)”. Try naming it as it appears in your list.",
                      item: nil, didMutate: false)
    }

    // MARK: - Matching (deterministic)

    /// Find the item the user meant: exact title first, then a contains match, then the
    /// best word-overlap score. Returns nil rather than guessing when nothing is close.
    static func matchItem(_ target: String, in items: [PlannerItem]) -> PlannerItem? {
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
        return scored.first?.0
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
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    @Generable
    fileprivate struct CommandDraft {
        @Guide(description: "One of: add, complete, reschedule, move, assign, rename. Use \"add\" when the user is describing something new to do.")
        var action: String

        @Guide(description: "For anything other than add: the existing item's title, copied from the user's words. Empty for add.")
        var target: String

        @Guide(description: "The list name, if the user named one. Otherwise empty.")
        var listName: String

        @Guide(description: "The person's name, if the user is assigning to someone. Otherwise empty.")
        var assignee: String

        @Guide(description: "The new title, only for a rename. Otherwise empty.")
        var newTitle: String
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
                exists. Copy names and titles from the user's own words — never invent them. \
                Never guess a date; the app parses dates separately.
                """)
            if let response = try? await session.respond(to: "Request: \"\(text)\"",
                                                         generating: CommandDraft.self) {
                let d = response.content
                return ParsedCommand(
                    action: PlannerAction(rawValue: d.action.lowercased()) ?? .add,
                    target: d.target, listName: d.listName,
                    assignee: d.assignee, newTitle: d.newTitle)
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
        if lower.hasPrefix("reschedule ") {
            return ParsedCommand(action: .reschedule, target: after(["reschedule "]))
        }
        return ParsedCommand(action: .add)
    }
}
