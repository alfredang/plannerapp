import Foundation
import SwiftData
import CryptoKit

/// Bridges the agents' report files to iCloud so the iPhone can read them and reply:
///  * every page in the Hermes `reports/` folder is saved as an `AgentReport` (re-saved when
///    its content changes);
///  * every `ReportReply` — typed here or on the iPhone — is appended once to
///    ~/DigitalWorkforce/replies/replies.jsonl, the file the agents read at the start of a run.
@MainActor
final class UpdatesSync {
    static let shared = UpdatesSync()

    private var context: ModelContext?
    private var timer: Timer?

    nonisolated static var repliesURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("DigitalWorkforce/replies/replies.jsonl")
    }

    func start(container: ModelContainer) {
        guard context == nil else { return }
        context = container.mainContext
        sync()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sync() }
        }
    }

    func sync() {
        guard let context else { return }
        uploadReports(context)
        exportReplies(context)
    }

    // MARK: Reports → iCloud

    private struct IndexEntry: Decodable {
        var file: String
        var title: String?
        var agent: String?
        var date: String?
        var summary: String?
        var modified: Int?
    }

    private func uploadReports(_ context: ModelContext) {
        let dir = AgentBrowser.reportsURL
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("index.json")),
              let entries = try? JSONDecoder().decode([IndexEntry].self, from: data) else { return }
        let existing = (try? context.fetch(FetchDescriptor<AgentReport>())) ?? []
        var byFile: [String: AgentReport] = [:]
        for report in existing { byFile[report.file] = report }
        var changed = false
        for entry in entries {
            guard let html = try? String(contentsOf: dir.appendingPathComponent(entry.file), encoding: .utf8),
                  html.utf8.count < 700_000 else { continue }
            let displayHTML = ReportPresentation.title(html)
            let title = ReportPresentation.title(entry.title ?? entry.file)
            let hash = SHA256.hash(data: Data(displayHTML.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
            let report = byFile[entry.file] ?? {
                let new = AgentReport(file: entry.file)
                context.insert(new)
                return new
            }()
            guard report.contentHash != hash || report.title != title else { continue }
            report.title = title
            report.agent = entry.agent ?? ""
            report.dateKey = entry.date ?? String(entry.file.prefix(10))
            report.summary = entry.summary ?? ""
            report.html = displayHTML
            report.contentHash = hash
            report.modifiedAt = entry.modified.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date()
            changed = true
        }
        if changed { try? context.save() }
    }

    // MARK: Replies

    /// A reply typed in the Mac's browser tab.
    func addReply(page: String, item: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let context, !trimmed.isEmpty else { return }
        context.insert(ReportReply(page: page, item: item, text: trimmed, source: "mac"))
        try? context.save()
        exportReplies(context)
    }

    /// Appends every reply not yet in replies.jsonl (matched by its id).
    private func exportReplies(_ context: ModelContext) {
        let replies = ((try? context.fetch(FetchDescriptor<ReportReply>(sortBy: [SortDescriptor(\.createdAt)]))) ?? [])
        guard !replies.isEmpty else { return }
        let url = Self.repliesURL
        let known = Self.lines().compactMap { $0["id"] }
        let seen = Set(known)
        let fresh = replies.filter { !seen.contains($0.id.uuidString) }
        guard !fresh.isEmpty else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var out = Data()
        for reply in fresh {
            let record: [String: String] = [
                "id": reply.id.uuidString,
                "ts": ISO8601DateFormatter().string(from: reply.createdAt),
                "page": reply.page, "item": reply.item, "text": reply.text, "from": reply.source,
            ]
            if let line = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
                out.append(line); out.append(Data("\n".utf8))
            }
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(out); try? handle.close()
        } else {
            try? out.write(to: url)
        }
    }

    nonisolated private static func lines() -> [[String: String]] {
        guard let text = try? String(contentsOf: repliesURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String]
        }
    }

    nonisolated static func savedReplies(forPage page: String) -> [[String: String]] {
        lines().filter { $0["page"] == page }
    }
}
