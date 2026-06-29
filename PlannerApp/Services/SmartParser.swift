import Foundation
import NaturalLanguage

/// The structured result of interpreting a free-text / spoken phrase.
struct ParsedEntry {
    var title: String
    var kind: PlannerKind
    var date: Date?

    func makeItem() -> PlannerItem {
        PlannerItem(title: title, kind: kind, date: date)
    }
}

/// On-device "AI intelligence" that turns a natural-language phrase (typed or dictated) into a
/// structured planner entry. It detects dates/times with `NSDataDetector`, classifies the entry
/// as a task vs. an appointment, and cleans the leftover phrase into a tidy title.
///
/// This is intentionally provider-agnostic: the same `parse(_:)` entry point could be backed by
/// a remote LLM (e.g. the Claude API) later without changing any call sites.
enum SmartParser {

    /// Words that strongly imply a scheduled event.
    private static let appointmentCues: Set<String> = [
        "meeting", "meet", "appointment", "appt", "call", "lunch", "dinner", "breakfast",
        "interview", "flight", "doctor", "dentist", "visit", "session", "class", "event",
        "reservation", "booking", "conference", "standup", "sync", "demo", "presentation",
        "party", "pickup", "drop", "deadline", "due"
    ]

    /// Words that imply a plain to-do.
    private static let taskCues: Set<String> = [
        "buy", "remember", "remind", "todo", "task", "finish", "complete", "email",
        "text", "read", "write", "pay", "clean", "wash", "fix", "review", "send", "get",
        "pick", "order", "renew", "check"
    ]

    /// Leading filler that dictation tends to produce ("add a reminder to …").
    private static let leadingFiller: [String] = [
        "add a new", "add new", "add a", "add an", "add", "create a", "create an", "create",
        "new", "please", "can you", "i need to", "i have to", "i want to", "remind me to",
        "reminder to", "remind me", "note to", "schedule a", "schedule an", "schedule",
        "set up a", "set up", "make a", "to"
    ]

    static func parse(_ raw: String) -> ParsedEntry {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return ParsedEntry(title: "", kind: .task, date: nil) }

        // 1. Detect a date/time anywhere in the phrase.
        let detection = detectDate(in: text)

        // 2. Strip the matched date phrase so it doesn't clutter the title.
        var remainder = text
        if let range = detection?.range {
            remainder.removeSubrange(Range(range, in: remainder)!)
        }
        remainder = cleanTitle(remainder)

        // 3. Classify.
        let lower = text.lowercased()
        let words = Set(lower.split { !$0.isLetter }.map(String.init))
        let hasAppointmentCue = !words.isDisjoint(with: appointmentCues)
        let hasTaskCue = !words.isDisjoint(with: taskCues)

        let kind: PlannerKind
        if detection?.hasTime == true || hasAppointmentCue {
            kind = .appointment
        } else if hasTaskCue {
            kind = .task
        } else if detection != nil {
            // A bare date with no time still reads more like a scheduled item.
            kind = .appointment
        } else {
            kind = .task
        }

        let title = remainder.isEmpty ? text : remainder
        // Tasks keep an optional due date; appointments require one (default to soon).
        let date: Date? = {
            if let d = detection?.date { return d }
            return kind == .appointment ? defaultAppointmentDate() : nil
        }()

        return ParsedEntry(title: title.capitalizedFirst, kind: kind, date: date)
    }

    // MARK: - Date detection

    private struct DateDetection {
        let date: Date
        let range: NSRange
        let hasTime: Bool
    }

    private static func detectDate(in text: String) -> DateDetection? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = detector.firstMatch(in: text, options: [], range: range),
              let date = match.date else { return nil }

        // `NSDataDetector` reports midnight-with-no-time differently across phrasings; use a
        // heuristic: if the source phrase mentions a clock time or "am/pm", treat it as timed.
        let matched = (text as NSString).substring(with: match.range).lowercased()
        let hasTime = matched.contains(":")
            || matched.contains("am") || matched.contains("pm")
            || matched.contains("o'clock") || matched.contains("noon")
            || matched.contains("midnight") || matched.range(of: "\\b\\d{1,2}\\s?(am|pm)\\b",
                                                              options: .regularExpression) != nil

        return DateDetection(date: date, range: match.range, hasTime: hasTime)
    }

    private static func defaultAppointmentDate() -> Date {
        // Next top of the hour, today.
        let cal = Calendar.current
        let now = Date()
        let comps = cal.dateComponents([.year, .month, .day, .hour], from: now)
        return cal.date(from: comps).flatMap { cal.date(byAdding: .hour, value: 1, to: $0) } ?? now
    }

    // MARK: - Title cleanup

    private static func cleanTitle(_ input: String) -> String {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var lower = s.lowercased()

        var changed = true
        while changed {
            changed = false
            for filler in leadingFiller {
                if lower == filler { s = ""; lower = ""; changed = true; break }
                if lower.hasPrefix(filler + " ") {
                    s = String(s.dropFirst(filler.count + 1))
                    lower = s.lowercased()
                    changed = true
                    break
                }
            }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
            lower = s.lowercased()
        }

        // Trim dangling connector words left over after the date was removed.
        for trailing in [" at", " on", " by", " for", " to", " the", " a", " -", ","] {
            if lower.hasSuffix(trailing) {
                s = String(s.dropLast(trailing.count))
                lower = s.lowercased()
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    /// Capitalize only the first character, leaving the rest as the speaker said it.
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
