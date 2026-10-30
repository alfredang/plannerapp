import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// An appointment pulled out of whatever the user pasted, dictated or typed — a meeting
/// invite, a WhatsApp message, the text read off a screenshot. Shown as a card in the
/// appointment chat before it is saved.
struct AppointmentDraft: Equatable {
    var title: String = ""
    /// The start. Date-only appointments are stored at midnight (see `PlannerItem.isMissed`).
    var date: Date?
    var hasTime = false
    var end: Date?
    var location: String = ""
    var meetingLink: String = ""
    var details: String = ""
    var usedAppleIntelligence = false

    var isReady: Bool { !title.isEmpty && date != nil }

    /// The item's notes: details, then the location, end time and meeting link on the
    /// lines `PlannerItem.endDate` and `MeetingLink` already read — no schema change.
    var notes: String {
        var lines: [String] = []
        if !details.isEmpty { lines.append(details) }
        if !location.isEmpty { lines.append("Location: \(location)") }
        if let end, hasTime { lines.append("Ends at \(Self.clock.string(from: end))") }
        return MeetingLink.notes(lines.joined(separator: "\n"), settingLink: meetingLink)
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()
}

/// Turns free text into an `AppointmentDraft`.
///
/// With Apple Intelligence (iOS/macOS 26+) the on-device model reads the text and picks out
/// the title, location, details, and the date/time *phrases*. As everywhere else in the app,
/// the model never decides a date: each phrase it returns must appear verbatim in the
/// source, and `SmartParser` turns it into the actual date. Without the model the
/// deterministic parser does everything. Nothing leaves the device either way.
enum AppointmentExtractor {

    /// The model's context window is small; an invite's useful part is near the top.
    private static let modelCharacterLimit = 4000

    /// Draft a new appointment from `source` — the text read off a screenshot, a pasted
    /// invite, or what the user said. `request` is what they said *alongside* a screenshot
    /// ("add this to appointment", "it's at 3pm"): an instruction, never the title. A time
    /// with no day lands on `anchorDay` (the day picked in the calendar, else today).
    static func extract(from source: String, request: String = "",
                        anchorDay: Date = Date()) async -> AppointmentDraft {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = request.trimmingCharacters(in: .whitespacesAndNewlines)
        var draft = AppointmentDraft()
        guard !text.isEmpty else { return draft }
        draft.meetingLink = MeetingLink.find(in: text) ?? ""

        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *), modelIsAvailable {
            var prompt = ""
            if !request.isEmpty { prompt += "The user's request: \(request)\n\n" }
            prompt += "Text:\n\(text.prefix(modelCharacterLimit))"
            if let fields = await ask(prompt: prompt) {
                apply(fields, to: &draft, source: text, anchorDay: anchorDay)
                if !draft.title.isEmpty {
                    // A short typed request keeps the user's own words (same guard as the
                    // capture bar); a pasted invite may be summarised.
                    if isShortRequest(text), !IntentAssistant.isFaithful(title: draft.title, to: text) {
                        draft.title = SmartParser.parse(text).title
                    }
                    draft.usedAppleIntelligence = true
                    if draft.date == nil {
                        for when in bestStart(in: text) { setStart(when, on: &draft, anchorDay: anchorDay) }
                    }
                    applyRequestDate(request, to: &draft, anchorDay: anchorDay)
                    return draft
                }
            }
        }
        #endif

        fallbackExtract(text, into: &draft, anchorDay: anchorDay)
        applyRequestDate(request, to: &draft, anchorDay: anchorDay)
        return draft
    }

    /// "Add this, it's at 3pm" — a day or time the user states overrides the screenshot's.
    private static func applyRequestDate(_ request: String, to draft: inout AppointmentDraft,
                                         anchorDay: Date) {
        guard !request.isEmpty, let when = SmartParser.when(in: request) else { return }
        setStart(when, on: &draft, anchorDay: anchorDay)
    }

    /// Words that only confirm ("add this to appointment", "yes, save it") — nothing to
    /// change, just add the draft.
    static func isConfirmation(_ text: String) -> Bool {
        let filler: Set<String> = [
            "add", "save", "confirm", "book", "schedule", "create", "put", "yes", "ok", "okay",
            "sure", "go", "ahead", "do", "it", "this", "that", "to", "into", "in", "my", "the",
            "a", "an", "as", "please", "pls", "appointment", "appointments", "calendar",
            "event", "meeting", "planner", "thanks", "thank", "you", "done", "looks", "good",
        ]
        let words = text.lowercased().split { !$0.isLetter }.map(String.init)
        return !words.isEmpty && words.count <= 10 && words.allSatisfy(filler.contains)
            && SmartParser.when(in: text) == nil
    }

    /// Apply a follow-up message ("make it 4pm", "it's at the Raffles Place office") to the
    /// current draft. Returns the draft unchanged when nothing in the message applies.
    static func revise(_ current: AppointmentDraft, with correction: String,
                       anchorDay: Date = Date()) async -> AppointmentDraft {
        let text = correction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return current }
        var draft = current
        if let link = MeetingLink.find(in: text) { draft.meetingLink = link }

        // Dates come only from the user's own words, never from the model.
        // "ends at 5pm" / "until 5pm": the date detector reads those as a range and
        // reports its start, so the cue is dropped before reading the time.
        let endCue = #"(?i)\b(ends?|ending|finish(es)?|until|till)\b(\s+at)?"#
        if text.range(of: endCue, options: .regularExpression) != nil, let start = draft.date {
            let time = text.replacingOccurrences(of: endCue, with: " ", options: .regularExpression)
            if let when = SmartParser.when(in: time), when.hasTime,
               let end = combine(when, onto: start), end > start {
                draft.end = end
            }
        } else if let when = SmartParser.when(in: text) {
            setStart(when, on: &draft, anchorDay: anchorDay)
        }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *), modelIsAvailable {
            let prompt = """
                Current appointment:
                Title: \(draft.title)
                Location: \(draft.location)
                Details: \(draft.details)

                The user's change: \(text)
                """
            if let fields = await ask(prompt: prompt, revising: true) {
                let title = fields.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { draft.title = title }
                draft.location = fields.location.trimmingCharacters(in: .whitespacesAndNewlines)
                draft.details = fields.details.trimmingCharacters(in: .whitespacesAndNewlines)
                draft.usedAppleIntelligence = true
            }
            return draft
        }
        #endif

        // No model: a message with no date and no link, sent while the draft has no
        // title yet, is the answer to "what's it called?".
        if current.title.isEmpty, draft.date == current.date, draft.meetingLink == current.meetingLink {
            draft.title = SmartParser.parse(text).title
        }
        return draft
    }

    // MARK: - Deterministic path

    private static func fallbackExtract(_ text: String, into draft: inout AppointmentDraft,
                                        anchorDay: Date) {
        if isShortRequest(text) {
            draft.title = SmartParser.parse(text).title
        } else {
            // A pasted block: the first line that isn't a date, a link or a label is
            // usually the event name; the rest is worth keeping as details.
            let lines = text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let titleIndex = lines.firstIndex { line in
                line.count >= 4 && SmartParser.when(in: line) == nil
                    && MeetingLink.find(in: line) == nil && !line.contains("://")
            }
            if let titleIndex {
                draft.title = String(stripReplyPrefix(lines[titleIndex]).prefix(80))
                draft.details = lines.enumerated()
                    .filter { $0.offset != titleIndex && MeetingLink.find(in: $0.element) == nil }
                    .prefix(8).map(\.element).joined(separator: "\n")
            }
        }
        for when in bestStart(in: text) { setStart(when, on: &draft, anchorDay: anchorDay) }
    }

    /// "Re: Fwd: Invitation: Kickoff" → "Kickoff".
    private static func stripReplyPrefix(_ line: String) -> String {
        line.replacingOccurrences(
            of: #"^(?i)(\s*(re|fwd?|fw|invitation|updated invitation|accepted)\s*:\s*)+"#,
            with: "", options: .regularExpression)
    }

    /// The appointment's start in `text`, as the `When`s to apply in order.
    ///
    /// A one-liner is read whole. A pasted block or screenshot is read line by line, since
    /// it usually holds other times too — an email's "5:52 PM (4 hours ago)" sits above
    /// "confirm this meeting on Monday 1pm". Send stamps and past days are skipped; a line
    /// with both day and time, or with meeting words, wins; a day line followed by a time
    /// line ("Date: …" / "Time: …") counts as one.
    static func bestStart(in text: String) -> [SmartParser.When] {
        if isShortRequest(text) { return SmartParser.when(in: text).map { [$0] } ?? [] }
        let lines = text.components(separatedBy: .newlines)
        let today = Calendar.current.startOfDay(for: Date())
        let sentStamp = #"(?i)\bago\b|\bwrote:|\bsent:|^\s*(from|to|cc|date sent)\s*:"#
        let cue = #"(?i)\b(meet|meeting|confirm|confirmed|appointment|call|date|time|when|"#
            + #"schedule|scheduled|lunch|dinner|breakfast|session|interview|visit|class|event|start)"#

        var best: (score: Int, whens: [SmartParser.When])?
        for (i, line) in lines.enumerated() {
            guard line.range(of: sentStamp, options: .regularExpression) == nil,
                  let when = SmartParser.when(in: line) else { continue }
            if when.hasDay && when.date < today { continue }
            var whens = [when]
            var score = (when.hasDay ? 2 : 0) + (when.hasTime ? 2 : 0)
            if line.range(of: cue, options: .regularExpression) != nil { score += 3 }
            if when.hasDay && !when.hasTime {
                let next = lines[(i + 1)..<min(i + 3, lines.count)]
                if let time = next.lazy.compactMap({ SmartParser.when(in: $0) })
                    .first(where: { $0.hasTime && !$0.hasDay }) {
                    whens.append(time)
                    score += 2
                }
            }
            if score > (best?.score ?? -1) { best = (score, whens) }
        }
        return best?.whens ?? []
    }

    private static func isShortRequest(_ text: String) -> Bool {
        text.count <= 140 && !text.contains("\n")
    }

    // MARK: - Dates

    /// Put `when` onto the draft's start: a time alone keeps the draft's day (else the
    /// anchor day), a day alone keeps the draft's time.
    private static func setStart(_ when: SmartParser.When, on draft: inout AppointmentDraft,
                                 anchorDay: Date) {
        let cal = Calendar.current
        if when.hasDay && when.hasTime {
            draft.date = when.date
            draft.hasTime = true
        } else if when.hasTime {
            draft.date = combine(when, onto: draft.date ?? anchorDay)
            draft.hasTime = true
        } else if let existing = draft.date, draft.hasTime {
            let time = cal.dateComponents([.hour, .minute], from: existing)
            draft.date = cal.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0,
                                  second: 0, of: when.date)
        } else {
            draft.date = cal.startOfDay(for: when.date)
            draft.hasTime = false
        }
        if let end = draft.end, let start = draft.date, end <= start { draft.end = nil }
    }

    /// `when`'s clock time on `day`.
    private static func combine(_ when: SmartParser.When, onto day: Date) -> Date? {
        let cal = Calendar.current
        let time = cal.dateComponents([.hour, .minute], from: when.date)
        return cal.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: day)
    }

    /// True when `phrase` (whitespace and case aside) appears in `source` — the check that
    /// keeps a model-chosen date phrase honest.
    private static func appears(_ phrase: String, in source: String) -> Bool {
        func squash(_ s: String) -> String {
            s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let p = squash(phrase)
        return !p.isEmpty && squash(source).contains(p)
    }

    // MARK: - Apple Intelligence

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    private static var modelIsAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    @available(iOS 26.0, macOS 26.0, *)
    @Generable
    fileprivate struct AppointmentFields {
        @Guide(description: "A short title for the appointment, e.g. \"Lunch with Sam\" or \"UOB AI training kickoff\". Use names and wording from the text. No date or time in the title, no trailing punctuation")
        var title: String
        @Guide(description: "The appointment's date exactly as written in the text, copied character for character, e.g. \"Tuesday, 4 November 2026\" or \"tomorrow\". Empty if no date is given")
        var startDate: String
        @Guide(description: "The start time exactly as written in the text, copied character for character, e.g. \"10:00 AM\" or \"3pm\". Empty if no time is given")
        var startTime: String
        @Guide(description: "The end time exactly as written in the text, copied character for character. Empty if not given")
        var endTime: String
        @Guide(description: "The venue or address, e.g. \"Level 12, UOB Plaza\". Empty if it is an online meeting or no place is given")
        var location: String
        @Guide(description: "Up to three short lines worth keeping: who is involved, the agenda, a dial-in number or passcode. Empty if there is nothing useful. Never repeat the title, date, time, location or meeting link")
        var details: String
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func ask(prompt: String, revising: Bool = false) async -> AppointmentFields? {
        let instructions = revising
            ? """
              You update an appointment in a calendar app. Apply the user's change to the \
              current appointment and return it in full; keep every field the change does not \
              mention exactly as it is. Leave the date and time fields empty.
              """
            : """
              You read meeting invites, emails, chat messages and screenshots and pull out \
              ONE appointment for a calendar app. Copy dates and times exactly as they appear \
              in the text. Ignore when a message was sent or received (stamps like \
              "5:52 PM (4 hours ago)"); use the time the meeting itself happens. If several \
              events are listed, take the first upcoming one. A request from the user, if \
              any, is an instruction, not part of the appointment. For an email, a good title \
              names the other person or company and the topic, e.g. "Meeting with Stylus Yeo \
              – AI training system proposal"; drop "Re:" and "Fwd:". Never invent details \
              that are not in the text.
              """
        let session = LanguageModelSession(instructions: instructions)
        do {
            return try await session.respond(to: prompt, generating: AppointmentFields.self).content
        } catch {
            return nil                                  // any model hiccup -> deterministic path
        }
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func apply(_ fields: AppointmentFields, to draft: inout AppointmentDraft,
                              source: String, anchorDay: Date) {
        func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        draft.title = clean(fields.title)
        draft.location = clean(fields.location)
        draft.details = clean(fields.details)

        // Invites often split the day and the time across lines ("Date: …" / "Time: …"),
        // so each phrase is checked against the source and parsed on its own.
        let datePhrase = clean(fields.startDate), timePhrase = clean(fields.startTime)
        if appears(datePhrase, in: source), let when = SmartParser.when(in: datePhrase) {
            setStart(when, on: &draft, anchorDay: anchorDay)
        }
        if appears(timePhrase, in: source), let when = SmartParser.when(in: timePhrase), when.hasTime {
            setStart(SmartParser.When(date: when.date, hasTime: true, hasDay: false),
                     on: &draft, anchorDay: anchorDay)
        }
        let endPhrase = clean(fields.endTime)
        if let start = draft.date, draft.hasTime, appears(endPhrase, in: source),
           let when = SmartParser.when(in: endPhrase), when.hasTime,
           let end = combine(when, onto: start), end > start {
            draft.end = end
        }
    }
    #endif
}
