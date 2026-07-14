import SwiftUI
import SwiftData

/// Chat-style capture — the app's front door. Tell the assistant what you need to do, by text
/// or voice, and it drafts a nicely worded to-do or appointment and saves it instantly.
struct AssistantChatView: View {
    @Environment(\.modelContext) private var context

    // Created only when the user first taps the mic. Constructing a SpeechRecognizer touches the
    // speech/audio stack and triggers the microphone permission prompt, so it must NOT exist at
    // launch — TabView eagerly initializes every tab's @State, which would otherwise prompt on the
    // very first screen. Keeping it nil until needed is what makes the assistant open silently.
    @State private var speech: SpeechRecognizer?
    @State private var messages: [ChatMessage] = [.greeting]
    @State private var input = ""
    @State private var isThinking = false
    @FocusState private var inputFocused: Bool

    private var isListening: Bool { speech?.isListening ?? false }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                thread
                inputBar
            }
            .background(Theme.bg)
            .navigationTitle("Assistant")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: speech?.transcript) { _, text in
                if let text, !text.isEmpty { input = text }
            }
            .onChange(of: speech?.state) { old, new in
                // When dictation finishes with text in the box, send it automatically.
                if old == .listening, new == .idle,
                   !input.trimmingCharacters(in: .whitespaces).isEmpty {
                    send()
                }
            }
        }
    }

    // MARK: - Thread

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(messages) { message in
                        ChatBubble(message: message, onUndo: undo)
                            .id(message.id)
                    }
                    if isThinking {
                        HStack {
                            ProgressView()
                            Text("Drafting…").font(.footnote).foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal)
                        .id("thinking")
                    }
                }
                .padding(.vertical, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture { inputFocused = false }
            .onChange(of: messages.count) {
                withAnimation {
                    proxy.scrollTo(messages.last?.id, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField(isListening ? "Listening…" : "e.g. “Lunch with Sam tomorrow 1pm”",
                      text: $input, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.card, in: Capsule())
                .focused($inputFocused)
                .onSubmit(send)

            Button {
                // Construct the recognizer lazily and request permission contextually, on first
                // mic use — never at launch.
                let recognizer = speech ?? SpeechRecognizer()
                if speech == nil { speech = recognizer }
                Task {
                    await recognizer.requestAuthorization()
                    withAnimation { recognizer.toggle() }
                }
            } label: {
                Image(systemName: isListening ? "stop.fill" : "mic.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(isListening ? Color.red : Theme.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isListening ? "Stop dictation" : "Dictate")

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(canSend ? Theme.accent : Color.secondary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isThinking
    }

    // MARK: - Actions

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isThinking else { return }
        speech?.stop()
        inputFocused = false
        input = ""
        messages.append(ChatMessage(role: .user, text: text))
        isThinking = true

        Task {
            let draft = await IntentAssistant.draft(from: text)
            var saved: PlannerItem?
            if !draft.entry.title.isEmpty {
                let item = draft.entry.makeItem()
                context.insert(item)
                saved = item
            }
            messages.append(ChatMessage(role: .assistant,
                                        text: draft.reply,
                                        item: saved.map(ChatMessage.ItemSummary.init)))
            isThinking = false
        }
    }

    private func undo(_ itemID: UUID) {
        guard let item = try? context.fetch(FetchDescriptor<PlannerItem>()).first(where: { $0.id == itemID })
        else { return }
        context.delete(item)
        messages.append(ChatMessage(role: .assistant, text: "Removed “\(item.title)”."))
    }
}

// MARK: - Bubble

private struct ChatBubble: View {
    let message: ChatMessage
    var onUndo: (UUID) -> Void

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 48) }

            VStack(alignment: .leading, spacing: 8) {
                Text(message.text)
                if let item = message.item {
                    itemCard(item)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                message.role == .user ? Theme.accent : Theme.card,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .foregroundStyle(message.role == .user ? .white : .primary)

            if message.role == .assistant { Spacer(minLength: 48) }
        }
        .padding(.horizontal)
    }

    private func itemCard(_ item: ChatMessage.ItemSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(item.kind.title, systemImage: item.kind.symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.accent)
            Text(item.title).font(.subheadline.weight(.medium))
            if let date = item.date {
                Label(date.formatted(.dateTime.weekday().month().day().hour().minute()),
                      systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Undo") { onUndo(item.id) }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

#Preview {
    AssistantChatView()
        .modelContainer(for: PlannerItem.self, inMemory: true)
}
