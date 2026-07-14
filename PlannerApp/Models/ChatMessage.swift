import Foundation

/// One turn in the assistant conversation, shared by the iOS chat tab and the macOS capture
/// bar. Carries an optional summary of the planner item the assistant saved for that turn.
struct ChatMessage: Identifiable {
    enum Role { case user, assistant }

    struct ItemSummary {
        let id: UUID
        let title: String
        let kind: PlannerKind
        let date: Date?

        init(_ item: PlannerItem) {
            id = item.id
            title = item.title
            kind = item.kind
            date = item.date
        }
    }

    let id = UUID()
    let role: Role
    let text: String
    var item: ItemSummary?

    static let greeting = ChatMessage(
        role: .assistant,
        text: "Hi! Tell me what you need to do — type it or tap the mic. " +
              "Try “Dentist appointment Friday 3pm” or “Buy groceries”."
    )
}
