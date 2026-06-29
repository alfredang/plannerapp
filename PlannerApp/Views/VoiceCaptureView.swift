import SwiftUI
import SwiftData

/// Voice-activated capture. Tap the mic, speak (native iOS speech-to-text), and the on-device
/// `SmartParser` interprets what you said into a to-do or appointment, which you can confirm.
struct VoiceCaptureView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var speech = SpeechRecognizer()
    @State private var parsed: ParsedEntry?

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()

                transcriptArea

                Spacer()

                if let parsed, !parsed.title.isEmpty {
                    parsedPreview(parsed)
                }

                micButton

                Text(promptText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Spacer(minLength: 12)
            }
            .padding()
            .navigationTitle("Add by Voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { speech.stop(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(parsed?.title.isEmpty ?? true)
                }
            }
            .task { await speech.requestAuthorization() }
            .onChange(of: speech.transcript) { _, text in
                guard !text.isEmpty else { return }
                parsed = SmartParser.parse(text)
            }
            .onDisappear { speech.stop() }
        }
    }

    private var transcriptArea: some View {
        VStack(spacing: 8) {
            if speech.transcript.isEmpty {
                Text(speech.isListening ? "Listening…" : "Tap the mic and speak")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            } else {
                Text("\u{201C}\(speech.transcript)\u{201D}")
                    .font(.title2.weight(.medium))
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 80)
        .padding(.horizontal)
    }

    private func parsedPreview(_ entry: ParsedEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(entry.kind.title, systemImage: entry.kind.symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.accent)
            Text(entry.title).font(.headline)
            if let date = entry.date {
                Label(date.formatted(.dateTime.weekday().month().day().hour().minute()),
                      systemImage: "clock")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .padding(.horizontal)
    }

    private var micButton: some View {
        Button {
            withAnimation { speech.toggle() }
        } label: {
            ZStack {
                Circle()
                    .fill(speech.isListening ? Color.red : Theme.accent)
                    .frame(width: 92, height: 92)
                    .shadow(radius: speech.isListening ? 12 : 4)
                Image(systemName: speech.isListening ? "stop.fill" : "mic.fill")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(speech.isListening ? "Stop recording" : "Start recording")
        .disabled(speech.state == .unauthorized || speech.state == .unavailable)
    }

    private var promptText: String {
        switch speech.state {
        case .unauthorized:
            return "Enable Microphone and Speech Recognition in Settings to add items by voice."
        case .unavailable:
            return "Speech recognition isn’t available on this device right now."
        default:
            return "Try: “Lunch with Sam tomorrow at 1pm” or “Buy groceries”."
        }
    }

    private func save() {
        guard let entry = parsed, !entry.title.isEmpty else { return }
        speech.stop()
        context.insert(entry.makeItem())
        dismiss()
    }
}

#Preview {
    VoiceCaptureView()
        .modelContainer(for: PlannerItem.self, inMemory: true)
}
