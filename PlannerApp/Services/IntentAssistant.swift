import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// What the assistant produced for one user utterance: the structured entry that was (or can
/// be) saved, plus a friendly reply for the chat thread.
struct AssistantDraft {
    var entry: ParsedEntry
    var reply: String
    var usedAppleIntelligence: Bool
}

/// Turns a free-text / spoken intent into a nicely worded planner entry.
///
/// On devices with Apple Intelligence (iOS 26+, model available) it uses the ON-DEVICE
/// FoundationModels framework to classify the intent and draft a polished title. Everywhere
/// else it falls back to the deterministic `SmartParser`. Nothing ever leaves the device —
/// both paths are fully local, matching the app's no-third-party-AI privacy stance.
enum IntentAssistant {

    /// Drafts a planner entry from raw text. Never throws — the fallback parser always answers.
    static func draft(from raw: String) async -> AssistantDraft {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = SmartParser.parse(text)

        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability,
               let polished = await polish(text: text, fallback: fallback) {
                return polished
            }
        }
        #endif

        return AssistantDraft(entry: fallback,
                              reply: confirmation(for: fallback, polished: false),
                              usedAppleIntelligence: false)
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    @Generable
    fileprivate struct ItemDraft {
        @Guide(description: "\"task\" for a simple to-do, \"appointment\" for anything scheduled at a time or place")
        var kind: String

        @Guide(description: "The item's title. Copy the user's own wording verbatim, only trimming filler like \"add\" or \"remind me to\". Never add words the user did not write — no \"Attend\", no \"Meeting\", no invented verbs. No trailing punctuation")
        var title: String

        @Guide(description: "A one-sentence friendly confirmation to show the user")
        var confirmation: String
    }

    /// Ask the on-device model to classify + word the entry. Dates still come from the
    /// deterministic `SmartParser` (NSDataDetector) because clock math must never hallucinate.
    @available(iOS 26.0, macOS 26.0, *)
    private static func polish(text: String, fallback: ParsedEntry) async -> AssistantDraft? {
        let session = LanguageModelSession(instructions: """
            You turn short natural-language requests into planner entries. \
            Classify each request as a "task" (simple to-do) or an "appointment". \
            Only call it an "appointment" when the request names an actual time, date, \
            or a meeting with someone. A bare name, title, or course with no time is a \
            "task" — when in doubt, choose "task". \
            For the title, reuse the user's own words, but DO fix spelling, capitalisation \
            and obvious grammar mistakes ("sumit ato" becomes "Submit ATO", "googel" \
            becomes "Google"). Strip leading filler such as "add" or "remind me to". \
            Never introduce words the user did not write — do not prepend verbs like \
            "Attend" — and do not invent details.
            """)
        do {
            let response = try await session.respond(
                to: "Request: \"\(text)\"",
                generating: ItemDraft.self
            )
            let d = response.content
            var kind: PlannerKind = d.kind.lowercased().contains("appointment") ? .appointment : .task
            var title = d.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }

            // Guard 1: the model sometimes prepends a verb the user never typed
            // ("Attend WSQ — …"). Trust the model's wording only when it stays within
            // the user's own words; otherwise keep what they actually wrote.
            if !isFaithful(title: title, to: text) {
                title = fallback.title.isEmpty ? text : fallback.title
            }

            // Guard 2: an appointment with no date is meaningless, and the model likes to
            // label bare course/product names as appointments. Only honour "appointment"
            // when a real date was actually detected in the text.
            if kind == .appointment, fallback.date == nil {
                kind = .task
            }

            var entry = fallback                       // keeps the detected date
            entry.title = title
            entry.kind = kind
            entry.date = fallback.date                 // dates only ever come from the parser

            let reply = d.confirmation.isEmpty
                ? confirmation(for: entry, polished: true)
                : d.confirmation
            return AssistantDraft(entry: entry, reply: reply, usedAppleIntelligence: true)
        } catch {
            return nil                                  // any model hiccup -> deterministic path
        }
    }
    #endif

    /// True when `title` says the same thing the user did — allowing spelling and grammar
    /// fixes, but not invented content.
    ///
    /// The model is asked to tidy wording, and *should* fix typos ("Googel" → "Google",
    /// "Sumit" → "Submit"). What it must not do is add meaning the user never wrote — most
    /// visibly prefixing a verb ("Attend WSQ – …") onto a title typed out in full. So a new
    /// word is accepted only when it is a close spelling variant of a word the user typed;
    /// anything else is rejected and the user's own phrasing survives.
    static func isFaithful(title: String, to original: String) -> Bool {
        func words(_ s: String) -> [String] {
            s.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count > 2 }          // ignore "a", "to", "of", "in" …
        }
        let source = Set(words(original))
        guard !source.isEmpty else { return true }
        let introduced = words(title).filter { !source.contains($0) }
        // Every introduced word must plausibly be a correction of something the user typed.
        return introduced.allSatisfy { candidate in
            source.contains { isLikelyCorrection(of: $0, to: candidate) }
        }
    }

    /// Whether `corrected` reads as a typo-fix of `typed` — same rough shape, small edit
    /// distance. Deliberately tight: "googel"→"google" passes, "wsq"→"attend" does not.
    static func isLikelyCorrection(of typed: String, to corrected: String) -> Bool {
        if typed == corrected { return true }
        // Length must be close; a correction doesn't change a word's size much.
        guard abs(typed.count - corrected.count) <= 2 else { return false }
        let budget = max(typed.count, corrected.count) <= 4 ? 1 : 2
        return editDistance(typed, corrected) <= budget
    }

    /// Standard Levenshtein distance, iterative single-row.
    private static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1,        // deletion
                                 current[j - 1] + 1,     // insertion
                                 previous[j - 1] + cost) // substitution
            }
            swap(&previous, &current)
        }
        return previous[y.count]
    }

    private static func confirmation(for entry: ParsedEntry, polished: Bool) -> String {
        guard !entry.title.isEmpty else {
            return "I couldn't make an item out of that — try something like “Lunch with Sam tomorrow at 1pm”."
        }
        switch entry.kind {
        case .appointment:
            if let date = entry.date {
                let when = date.formatted(.dateTime.weekday(.wide).month().day().hour().minute())
                return "Scheduled “\(entry.title)” for \(when)."
            }
            return "Scheduled “\(entry.title)”."
        case .task:
            if let date = entry.date {
                let when = date.formatted(.dateTime.weekday(.wide).month().day())
                return "Added “\(entry.title)” to your to-dos, due \(when)."
            }
            return "Added “\(entry.title)” to your to-dos."
        }
    }
}
