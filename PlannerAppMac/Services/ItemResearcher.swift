import Foundation
import SwiftData
import Observation

/// Turns an idea or a goal into a researched page: Nova examines it, researches the web and
/// writes it up (review, market research, competitor analysis, features, recommendations,
/// strategy, steps to implement, caveats), and the report pipeline renders it. The page's link
/// goes on the item's notes (`PageLink`), which `MacResearchPagesView` shows; the iPhone sees the
/// same notes, and the page itself reaches the iPhone through Updates.
///
/// Runs right after an item is added and every minute for ones from elsewhere (an agent, the
/// iPhone, or left while Planner was closed). An item is researched once; a failed run isn't
/// retried, so a broken agent can't loop or keep spending — "Research Again" is the way back.
@MainActor
@Observable
final class ItemResearcher {
    static let shared = ItemResearcher()

    static let agentName = "Nova"

    /// Each run is a long, costly research session, so only this many go at once.
    private static let maxConcurrent = 2

    enum Status: Equatable {
        case researching, queued, failed, unavailable
    }

    /// Items being researched right now.
    private(set) var running: Set<UUID> = []
    /// Items whose research has finished, kept across launches. One here without a page failed.
    private var attempted: Set<UUID> {
        didSet {
            UserDefaults.standard.set(attempted.map(\.uuidString), forKey: Self.attemptedKey)
        }
    }
    /// Items asked to run again, waiting for a free slot.
    private var again: Set<UUID> = []

    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var timer: Timer?

    private static let attemptedKey = "itemResearcher.attempted"

    private init() {
        let saved = UserDefaults.standard.stringArray(forKey: Self.attemptedKey) ?? []
        attempted = Set(saved.compactMap(UUID.init(uuidString:)))
    }

    nonisolated static var scriptURL: URL {
        #if DEBUG
        // A UI test can stand in a fake script, so it doesn't run real research or publish.
        if let path = UserDefaults.standard.string(forKey: "researchScript") {
            return URL(fileURLWithPath: path)
        }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("DigitalWorkforce/bin/research-item.sh")
    }

    func start(container: ModelContainer) {
        guard context == nil else { return }
        context = container.mainContext
        sweep()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sweep() }
        }
    }

    /// What a row shows, or `nil` once the item has its page (the row's "Open page" takes over).
    func status(of item: PlannerItem) -> Status? {
        if running.contains(item.id) { return .researching }
        if again.contains(item.id) { return .queued }
        guard item.pageTarget == nil, item.isResearched, !item.isDone else { return nil }
        if attempted.contains(item.id) { return .failed }
        return FileManager.default.fileExists(atPath: Self.scriptURL.path) ? .queued : .unavailable
    }

    /// Starts research on waiting items, oldest first, up to the concurrency limit.
    func sweep() {
        guard let context, FileManager.default.fileExists(atPath: Self.scriptURL.path) else { return }
        let items = (try? context.fetch(FetchDescriptor<PlannerItem>(
            sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        let open = items.filter { $0.isResearched && !$0.isArchived && !$0.isDone }
        // Asked for again goes first: it was a direct request.
        let waiting = open.filter { again.contains($0.id) }
            + open.filter { !again.contains($0.id) && $0.pageTarget == nil && !attempted.contains($0.id) }
        let goals = open.filter(\.isGoal).map(\.title).joined(separator: "\n")
        for item in waiting where running.count < Self.maxConcurrent && !running.contains(item.id) {
            run(item, goals: goals)
        }
    }

    /// "Research Again": a new page replaces the old one (which stays in Updates as history).
    func researchAgain(_ item: PlannerItem) {
        attempted.remove(item.id)
        again.insert(item.id)
        sweep()
    }

    private func run(_ item: PlannerItem, goals: String) {
        let id = item.id
        let force = again.remove(id) != nil
        running.insert(id)
        let details = PageLink.withoutLink(item.displayNotes)
        let target = item.date?.formatted(.dateTime.day().month(.wide).year())
        let args = [item.kindRaw, id.uuidString, item.title, details]
        let script = Self.scriptURL
        Task.detached {
            let link = Self.runScript(script, args: args, goals: goals, target: target, force: force)
            await MainActor.run { self.finish(id: id, link: link, force: force) }
        }
    }

    private func finish(id: UUID, link: String?, force: Bool) {
        running.remove(id)
        attempted.insert(id)
        defer { sweep() }   // a slot is free: start the next one
        guard let context, let link,
              let item = try? context.fetch(FetchDescriptor<PlannerItem>(predicate: #Predicate { $0.id == id })).first,
              let url = PageLink.url(for: link, workspace: HermesBridge.workspaceURL),
              FileManager.default.fileExists(atPath: url.path) else { return }
        // An agent or the user linked a page during the run: only Research Again replaces it.
        guard force || item.pageTarget == nil else { return }
        item.notes = PageLink.notes(item.notes, setting: link)
        try? context.save()
    }

    /// The page link the script printed (its last line), or `nil` if the run failed.
    nonisolated private static func runScript(_ script: URL, args: [String], goals: String,
                                              target: String?, force: Bool) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = [script.path] + args
        var env = ProcessInfo.processInfo.environment
        env["GOALS"] = goals
        if let target { env["TARGET"] = target }
        if force { env["RESEARCH_FORCE"] = "1" }
        task.environment = env
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        // A stuck agent run shouldn't leave the row "researching" forever.
        let timeout = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1500, execute: timeout)
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        task.waitUntilExit()
        timeout.cancel()
        guard task.terminationStatus == 0 else { return nil }
        return output.split(whereSeparator: \.isNewline).last
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: - Capture

    /// A title and notes from what was typed or said: the first line (cut at a word near 80
    /// characters) is the title; anything longer keeps the full wording in the notes.
    nonisolated static func parts(of text: String) -> (title: String, notes: String) {
        let full = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = full.split(whereSeparator: \.isNewline).first.map(String.init) ?? full
        guard first.count > 80 else { return (first, first == full ? "" : full) }
        let cut = first.prefix(80)
        let words = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return (words.trimmingCharacters(in: .whitespaces) + "…", full)
    }

    /// A goal's target from what was said: "by 2027" or "in 2027" means the end of that year;
    /// otherwise the date parser's reading of a full date ("by 31 March 2027"). Midnight, like
    /// the form's target date. No date is fine: Nova proposes one.
    nonisolated static func goalTarget(in text: String) -> Date? {
        let cal = Calendar.current
        // The year first: the date parser would read "5 franchisees by 2027" as some day.
        let pattern = #"(?i)\b(?:by|in|before)\s+(?:the\s+)?(?:end\s+of\s+)?(20\d\d)\b"#
        if let match = text.range(of: pattern, options: .regularExpression),
           let year = Int(text[match].suffix(4)) {
            return cal.date(from: DateComponents(year: year, month: 12, day: 31))
        }
        guard let when = SmartParser.when(in: text), when.hasDay, when.date > Date() else { return nil }
        return cal.startOfDay(for: when.date)
    }

    /// Files what was typed or said on Ideas or Goals, and starts researching it.
    func add(_ text: String, kind: PlannerKind, list: PlannerList?, context: ModelContext) {
        let parts = Self.parts(of: text)
        let item = PlannerItem(title: parts.title, notes: parts.notes, kind: kind,
                               date: kind == .goal ? Self.goalTarget(in: text) : nil)
        item.list = list
        context.insert(item)
        try? context.save()
        sweep()
    }
}
