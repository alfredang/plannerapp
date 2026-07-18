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
            For the title, reuse the user's own words verbatim; only strip leading filler \
            such as "add" or "remind me to". Never introduce words the user did not write \
            (do not prepend verbs like "Attend"). Do not invent details.
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

    /// True when every significant word in `title` also appears in the user's original text.
    ///
    /// The on-device model is asked to reword, but it occasionally *adds* content — most
    /// visibly prefixing an invented verb ("Attend WSQ – …") onto a title the user typed in
    /// full. Rewording that only drops or reorders words is fine; anything that introduces a
    /// new word is rejected so the user's own phrasing survives.
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
        return introduced.isEmpty
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
