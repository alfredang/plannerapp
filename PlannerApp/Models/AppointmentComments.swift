import Foundation

/// Comments left on an appointment through "Reply / comment". Each one is a line in the
/// notes — "Comment (16 Oct, 9:12 AM): Rescheduled to next week" — so it syncs without a
/// new CloudKit field and the agents read it along with the rest of the notes. An agent's
/// answer is a line too — "Reply from Atlas (16 Oct, 9:14 AM): …" — so it shows on every device.
enum AppointmentComments {
    private static let prefix = "Comment ("
    private static let replyPrefix = "Reply from "

    struct Comment: Hashable {
        let stamp: String
        let text: String
        /// The agent that wrote it; nil for Alfred's own comments.
        var author: String? = nil
    }

    private static func stamp(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    static func line(_ text: String, at date: Date = Date()) -> String {
        "\(prefix)\(stamp(date))): \(text)"
    }

    static func replyLine(_ text: String, from agent: String, at date: Date = Date()) -> String {
        "\(replyPrefix)\(agent) (\(stamp(date))): \(text)"
    }

    static func parse(_ line: String) -> Comment? {
        guard let close = line.range(of: "): ") else { return nil }
        if line.hasPrefix(prefix) {
            let stamp = line[line.index(line.startIndex, offsetBy: prefix.count)..<close.lowerBound]
            return Comment(stamp: String(stamp), text: String(line[close.upperBound...]))
        }
        // "Reply from Atlas (stamp): text" — one-word agent name, then the stamp.
        guard line.hasPrefix(replyPrefix) else { return nil }
        let head = line[line.index(line.startIndex, offsetBy: replyPrefix.count)..<close.lowerBound]
        guard let open = head.range(of: " ("),
              !head[..<open.lowerBound].isEmpty, !head[..<open.lowerBound].contains(" ") else { return nil }
        return Comment(stamp: String(head[open.upperBound...]),
                       text: String(line[close.upperBound...]),
                       author: String(head[..<open.lowerBound]))
    }

    static func comments(in notes: String) -> [Comment] {
        notes.components(separatedBy: .newlines).compactMap(parse)
    }

    /// The notes without the comment lines (comments are shown on their own).
    static func withoutComments(_ notes: String) -> String {
        notes.components(separatedBy: .newlines)
            .filter { parse($0) == nil }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension PlannerItem {
    var comments: [AppointmentComments.Comment] { AppointmentComments.comments(in: notes) }

    func addComment(_ text: String) {
        // One comment per line, so multi-line input is flattened.
        let flat = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !flat.isEmpty else { return }
        let line = AppointmentComments.line(flat)
        notes = notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? line
            : notes.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" + line
    }

    /// Adds an agent's answer under the comments (flattened to one line, like a comment).
    func addAgentReply(_ text: String, from agent: String) {
        let flat = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !flat.isEmpty else { return }
        let line = AppointmentComments.replyLine(flat, from: agent)
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        notes = trimmed.isEmpty ? line : trimmed + "\n" + line
    }

    /// Alfred's newest comment, when no agent has answered it yet.
    var unansweredComment: AppointmentComments.Comment? {
        guard let last = comments.last, last.author == nil else { return nil }
        return last
    }
}

/// "Cancelled" and "Rescheduled", the other answers to "Did this happen?". Each is posted as
/// one of Alfred's comments, so it syncs like any comment and Atlas answers it.
extension PlannerItem {
    static let cancelledComment = "Cancelled. It did not happen."

    /// Marked "Cancelled": no longer missed, struck through, and can be undone.
    var isCancelled: Bool {
        isAppointment && comments.contains { $0.author == nil && $0.text == Self.cancelledComment }
    }

    func markCancelled() {
        guard !isCancelled else { return }
        addComment(Self.cancelledComment)
    }

    /// Takes the "Cancelled" comment back out (any answer to it stays).
    func undoCancelled() {
        notes = notes.components(separatedBy: .newlines)
            .filter { line in
                guard let c = AppointmentComments.parse(line) else { return true }
                return !(c.author == nil && c.text == Self.cancelledComment)
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Moves the appointment to `newDate` and notes where it came from.
    func reschedule(to newDate: Date) {
        if let old = date {
            addComment("Rescheduled from \(Self.slotText(old)) to \(Self.slotText(newDate)).")
        }
        date = newDate
    }

    /// "Fri 16 Oct, 3:00 PM", or just the day for a date-only (midnight) appointment.
    private static func slotText(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        let day = date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        guard parts.hour != 0 || parts.minute != 0 else { return day }
        return "\(day), \(date.formatted(.dateTime.hour().minute()))"
    }
}
