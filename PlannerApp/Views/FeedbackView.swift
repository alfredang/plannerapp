import SwiftUI

/// House-style feedback form: Title + Message → opens WhatsApp with the composed text.
struct FeedbackView: View {
    private let whatsAppNumber = "6588666375"   // +65 8866 6375, country code, no "+"/spaces

    @State private var title = ""
    @State private var message = ""

    private var canSend: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("We’d love your feedback")
                        .font(.title3.weight(.semibold))

                    VStack(alignment: .leading, spacing: 6) {
                        Text("TITLE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        TextField("Subject", text: $title)
                            .textFieldStyle(.plain)
                            .padding(12)
                            .background(Theme.card, in: Theme.rowShape)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("MESSAGE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ZStack(alignment: .topLeading) {
                            if message.isEmpty {
                                Text("Your message…")
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 20)
                            }
                            TextEditor(text: $message)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 160)
                                .padding(6)
                        }
                        .background(Theme.card, in: Theme.rowShape)
                    }

                    Button(action: send) {
                        Label("Send via WhatsApp", systemImage: "paperplane.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Theme.accent, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .disabled(!canSend)
                    .opacity(canSend ? 1 : 0.5)
                }
                .padding(22)
            }
            .navigationTitle("Feedback")
        }
    }

    private func send() {
        var text = ""
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let m = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { text += "*\(t)*\n" }
        text += m

        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "wa.me"
        comps.path = "/\(whatsAppNumber)"
        comps.queryItems = [URLQueryItem(name: "text", value: text)]
        if let url = comps.url { UIApplication.shared.open(url) }
    }
}

#Preview {
    FeedbackView()
}
