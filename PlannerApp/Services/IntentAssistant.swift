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

        @Guide(description: "A short, nicely worded title for the item, at most 8 words, no trailing punctuation")
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
            Classify each request as a "task" (simple to-do) or an "appointment" \
            (anything happening at a specific time, place, or with a person). \
            Rewrite the request as a clean, nicely worded title. Do not invent details.
            """)
        do {
            let response = try await session.respond(
                to: "Request: \"\(text)\"",
                generating: ItemDraft.self
            )
            let d = response.content
            let kind: PlannerKind = d.kind.lowercased().contains("appointment") ? .appointment : .task
            let title = d.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }

            var entry = fallback                       // keeps the detected date
            entry.title = title
            entry.kind = kind
            if kind == .appointment, entry.date == nil {
                entry.date = fallback.date
            }
            if kind == .task, fallback.kind == .task {
                entry.date = fallback.date             // optional due date stays as detected
            }

            let reply = d.confirmation.isEmpty
                ? confirmation(for: entry, polished: true)
                : d.confirmation
            return AssistantDraft(entry: entry, reply: reply, usedAppleIntelligence: true)
        } catch {
            return nil                                  // any model hiccup -> deterministic path
        }
    }
    #endif

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
