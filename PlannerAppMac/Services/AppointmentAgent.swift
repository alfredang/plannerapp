import Foundation
import SwiftData
import Observation

/// Answers Alfred's "Reply / comment" on an appointment: Atlas (who owns the schedule) reads
/// the comment, checks Calendar / Gmail / Planner, and its answer is added under the comment
/// as a "Reply from Atlas" line in the notes — so it syncs to the iPhone too.
///
/// Runs right after a comment is posted on the Mac, and every minute for comments that
/// arrived from the iPhone (or were left while Planner was closed). Each comment is asked
/// about once; a failed run is not retried, so a broken agent can't loop.
@MainActor
@Observable
final class AppointmentAgent {
    static let shared = AppointmentAgent()

    static let agentName = "Atlas"

    /// Appointments whose comment Atlas is working on.
    private(set) var pending: Set<UUID> = []
    /// Appointments whose last run failed, with the reason shown under the comment.
    private(set) var failed: [UUID: String] = [:]

    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var timer: Timer?

    nonisolated static var scriptURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("DigitalWorkforce/bin/answer-appointment-comment.sh")
    }

    /// Comments already asked about ("<item id>|<stamp>|<text>"), kept across launches.
    private static let askedKey = "appointmentAgent.asked"
    private var asked: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.askedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue.suffix(500)), forKey: Self.askedKey) }
    }

    func start(container: ModelContainer) {
        guard context == nil else { return }
        context = container.mainContext
        sweep()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sweep() }
        }
    }

    /// Asks Atlas about every appointment whose newest comment has no answer yet.
    func sweep() {
        guard let context else { return }
        let items = (try? context.fetch(FetchDescriptor<PlannerItem>())) ?? []
        for item in items where item.isAppointment && item.unansweredComment != nil {
            ask(item)
        }
    }

    func ask(_ item: PlannerItem) {
        guard let comment = item.unansweredComment, !pending.contains(item.id) else { return }
        let key = "\(item.id.uuidString)|\(comment.stamp)|\(comment.text)"
        guard !asked.contains(key) else { return }
        guard FileManager.default.fileExists(atPath: Self.scriptURL.path) else { return }

        pending.insert(item.id)
        failed[item.id] = nil
        let id = item.id
        let when = item.date?.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute()) ?? "no date"
        let details = AppointmentComments.withoutComments(item.notes)
        // Earlier comments and answers on this appointment, so a follow-up reads as a conversation.
        let thread = item.comments.dropLast().map { "\($0.author ?? "Alfred"): \($0.text)" }.joined(separator: "\n")
        let args = [item.title, when, item.isDone ? "ticked as done" : "not ticked", details, comment.text]
        let script = Self.scriptURL

        Task.detached {
            let answer = Self.run(script: script, args: args, thread: thread)
            await MainActor.run { self.finish(id: id, key: key, answer: answer) }
        }
    }

    private func finish(id: UUID, key: String, answer: String) {
        pending.remove(id)
        asked.insert(key)
        guard let context,
              let item = try? context.fetch(FetchDescriptor<PlannerItem>(predicate: #Predicate { $0.id == id })).first
        else { return }
        if answer.isEmpty {
            failed[id] = "\(Self.agentName) couldn't answer just now. Saved for the next scheduled run."
            return
        }
        item.addAgentReply(answer, from: Self.agentName)
        try? context.save()
    }

    nonisolated private static func run(script: URL, args: [String], thread: String) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = [script.path] + args
        var env = ProcessInfo.processInfo.environment
        env["THREAD"] = thread
        task.environment = env
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return "" }
        // A stuck agent run shouldn't leave the row "checking…" forever.
        let timeout = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 600, execute: timeout)
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        task.waitUntilExit()
        timeout.cancel()
        return task.terminationStatus == 0 ? output.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }
}
