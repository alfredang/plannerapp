import SwiftUI
import SwiftData
import PhotosUI
import Vision
import UniformTypeIdentifiers

/// "New Appointment" as a chat instead of a form: paste a screenshot or an invite, pick a
/// photo, dictate or type, and Apple Intelligence drafts the appointment as a card to check
/// before adding. Follow-ups ("make it 4pm", "it's at UOB Plaza") change the draft. The
/// classic form stays one tap away (toolbar, or Edit on the card), prefilled with the draft.
struct AppointmentChatView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    /// The day a bare time ("3pm") lands on — the day picked in the calendar, else today.
    var anchorDay: Date = Date()
    /// The list open on screen; a new appointment is filed there and inherits its owner.
    var defaultList: PlannerList?

    @State private var turns: [Turn] = [.greeting]
    @State private var draft: AppointmentDraft?
    @State private var input = ""
    @State private var attachment: UIImage?
    @State private var photoItem: PhotosPickerItem?
    /// "Reading the screenshot…" / "Drafting…" while work is in flight.
    @State private var status: String?
    // Created on first mic tap only, so opening the sheet never prompts for the microphone.
    @State private var speech: SpeechRecognizer?
    @State private var showingForm = false
    @State private var savedFromForm = false
    /// The user said "add this to appointment" before pasting: add as soon as it's drafted.
    @State private var addWhenDrafted = false
    @FocusState private var inputFocused: Bool

    private var isListening: Bool { speech?.isListening ?? false }
    private var isBusy: Bool { status != nil }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                thread
                inputBar
            }
            .background(Theme.bg)
            .navigationTitle("New Appointment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        speech?.stop()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showingForm = true } label: {
                        Image(systemName: "list.bullet.rectangle")
                    }
                    .accessibilityLabel("Use the form")
                }
            }
            .sheet(isPresented: $showingForm, onDismiss: {
                if savedFromForm { dismiss() }
            }) {
                AddItemView(prefill: formPrefill, defaultList: defaultList) {
                    savedFromForm = true
                }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                photoItem = nil
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        attachment = image
                        send()
                    }
                }
            }
            .onChange(of: speech?.transcript) { _, text in
                if let text, !text.isEmpty { input = text }
            }
            .onChange(of: speech?.state) { old, new in
                // Dictation finished with words in the box: send them.
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
                    ForEach(turns) { TurnBubble(turn: $0) }
                    if let draft {
                        DraftCard(draft: draft, onAdd: save, onEdit: { showingForm = true })
                            .padding(.horizontal)
                    }
                    if let status {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(status).font(.footnote).foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.vertical, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: turns.count) { scrollDown(proxy) }
            .onChange(of: draft) { scrollDown(proxy) }
            .onChange(of: status) { scrollDown(proxy) }
        }
    }

    private func scrollDown(_ proxy: ScrollViewProxy) {
        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let attachment {
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: attachment)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Button { self.attachment = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.6))
                    }
                    .offset(x: 6, y: -6)
                    .accessibilityLabel("Remove image")
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    circleIcon("photo")
                }
                .accessibilityLabel("Choose a photo")

                PasteButton(supportedContentTypes: [.image, .plainText]) { providers in
                    paste(providers)
                }
                .labelStyle(.iconOnly)
                .buttonBorderShape(.circle)
                .tint(Theme.accent)
                .disabled(isBusy)

                TextField(isListening ? "Listening…" : "Paste, say or type",
                          text: $input, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .focused($inputFocused)
                    .accessibilityIdentifier("appointmentChat.input")

                Button(action: toggleDictation) {
                    Image(systemName: isListening ? "stop.fill" : "mic.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(isListening ? Color.red : Theme.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isListening ? "Stop dictation" : "Dictate")

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(canSend ? Theme.accent : Color.secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("appointmentChat.send")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func circleIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .frame(width: 36, height: 36)
            .background(Theme.card, in: Circle())
    }

    private var canSend: Bool {
        (!input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachment != nil) && !isBusy
    }

    // MARK: - Actions

    private func toggleDictation() {
        let recognizer = speech ?? SpeechRecognizer()
        if speech == nil { speech = recognizer }
        Task {
            await recognizer.requestAuthorization()
            withAnimation { recognizer.toggle() }
        }
    }

    /// The system Paste button: an image (a copied screenshot) wins over text. Either is
    /// sent straight away — one tap from clipboard to draft.
    private func paste(_ providers: [NSItemProvider]) {
        Task { @MainActor in
            for provider in providers where provider.canLoadObject(ofClass: UIImage.self) {
                if let image = await provider.loadImage() {
                    attachment = image
                    send()
                    return
                }
            }
            for provider in providers where provider.canLoadObject(ofClass: NSString.self) {
                if let text = await provider.loadText(), !text.isEmpty {
                    input = input.isEmpty ? text : input + "\n" + text
                    send()
                    return
                }
            }
        }
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let image = attachment
        guard !text.isEmpty || image != nil, !isBusy else { return }
        speech?.stop()
        inputFocused = false
        input = ""
        attachment = nil
        turns.append(Turn(role: .user, text: text, image: image))

        // "Add this to appointment" with nothing new attached: that's the Add button.
        if image == nil, AppointmentExtractor.isConfirmation(text) {
            if let draft, draft.isReady { save() }
            else if draft == nil {
                addWhenDrafted = true
                say("Sure. Paste or pick the screenshot (or tell me the details) and I'll add it.")
            }
            else { say(reply(for: draft!, revisedFrom: nil)) }
            return
        }

        Task {
            // With a screenshot, its text is the appointment and what the user typed or said
            // alongside it is the instruction ("add this to appointment", "it's at 3pm").
            var source = text
            var request = ""
            if let image {
                status = "Reading the screenshot…"
                let read = await TextRecognizer.text(in: image)
                if read.isEmpty && text.isEmpty {
                    status = nil
                    say("I couldn't read any text in that image. Try a clearer screenshot, or type the details.")
                    return
                }
                if !read.isEmpty { (source, request) = (read, text) }
            }

            status = "Drafting…"
            // A new screenshot or a pasted block starts over; a short message tweaks the draft.
            let previous = draft
            let startsOver = previous == nil || image != nil || Self.looksLikeInvite(text)
            var next: AppointmentDraft
            if let previous, !startsOver {
                next = await AppointmentExtractor.revise(previous, with: source, anchorDay: anchorDay)
            } else {
                next = await AppointmentExtractor.extract(from: source, request: request,
                                                          anchorDay: anchorDay)
            }
            status = nil

            if next.title.isEmpty && next.date == nil {
                say(startsOver
                    ? "I couldn't find an appointment in that. Try something like “Lunch with Sam Friday 1pm”, or paste the invite."
                    : "I couldn't tell what to change. Tap Edit on the card to adjust it by hand.")
                return
            }
            next.title = next.title.trimmingCharacters(in: .whitespacesAndNewlines)
            withAnimation { draft = next }
            // Screenshot + "add this to appointment" (said with it or just before): the
            // user already asked for it to be added.
            let addNow = addWhenDrafted || AppointmentExtractor.isConfirmation(request)
            addWhenDrafted = false
            if next.isReady, addNow {
                save()
                return
            }
            say(reply(for: next, revisedFrom: startsOver ? nil : previous))
        }
    }

    private func reply(for draft: AppointmentDraft, revisedFrom previous: AppointmentDraft?) -> String {
        if let previous, previous == draft {
            return "I couldn't tell what to change. Tap Edit on the card to adjust it by hand."
        }
        if draft.title.isEmpty { return "What should I call it?" }
        if draft.date == nil { return "When is it? Tell me a day and time, like “Friday 3pm”." }
        if previous != nil { return "Updated. Anything else, or tap Add?" }
        return "Here's the appointment. Check it and tap Add, or tell me what to change."
    }

    private func say(_ text: String) {
        turns.append(Turn(role: .assistant, text: text))
    }

    /// Long or multi-line text is a pasted invite, not a correction to the current draft.
    private static func looksLikeInvite(_ text: String) -> Bool {
        text.count > 200 || text.components(separatedBy: .newlines).count > 2
    }

    private func save() {
        guard let draft, draft.isReady, let date = draft.date else { return }
        let item = PlannerItem(title: draft.title, notes: draft.notes, kind: .appointment, date: date)
        if let list = defaultList {
            item.list = list
            if let owner = list.derivedAssignee { item.assignedTo = owner }
        }
        context.insert(item)
        // Same follow-through as the capture bar: Calendar copy, immediate iCloud save, alerts.
        let ctx = context
        Task { await PlannerCommand.commit(CommandResult(reply: "", item: item, didMutate: true), context: ctx) }
        dismiss()
    }

    /// The draft as the form's prefill. With no date yet, the form opens on the anchor day
    /// at 9:00, like the calendar's own +.
    private var formPrefill: ParsedEntry {
        let start = draft?.date
            ?? Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: anchorDay)
        var notesOnly = draft ?? AppointmentDraft()
        notesOnly.meetingLink = ""                       // the form has its own link field
        return ParsedEntry(title: draft?.title ?? "", kind: .appointment, date: start,
                           notes: notesOnly.notes, meetingLink: draft?.meetingLink ?? "")
    }
}

// MARK: - Thread content

private struct Turn: Identifiable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
    var image: UIImage?

    static let greeting = Turn(
        role: .assistant,
        text: "Paste a screenshot or an invite, pick one from Photos, or just say it, "
            + "like “Lunch with Sam Friday 1pm”. I'll draft the appointment for you to check."
    )
}

private struct TurnBubble: View {
    let turn: Turn

    var body: some View {
        HStack {
            if turn.role == .user { Spacer(minLength: 48) }
            VStack(alignment: turn.role == .user ? .trailing : .leading, spacing: 6) {
                if let image = turn.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 160, maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                if !turn.text.isEmpty {
                    Text(turn.text)
                        .lineLimit(turn.role == .user ? 8 : nil)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(turn.role == .user ? Theme.accent : Theme.card,
                                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .foregroundStyle(turn.role == .user ? .white : .primary)
                }
            }
            if turn.role == .assistant { Spacer(minLength: 48) }
        }
        .padding(.horizontal)
    }
}

private struct DraftCard: View {
    let draft: AppointmentDraft
    var onAdd: () -> Void
    var onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Appointment", systemImage: "calendar")
                    .foregroundStyle(Theme.accent)
                Spacer()
                if draft.usedAppleIntelligence {
                    Label("Apple Intelligence", systemImage: "sparkles")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption.weight(.semibold))

            Text(draft.title.isEmpty ? "Untitled" : draft.title)
                .font(.headline)
                .foregroundStyle(draft.title.isEmpty ? .secondary : .primary)

            VStack(alignment: .leading, spacing: 6) {
                if let when = whenText {
                    Label(when, systemImage: "clock")
                } else {
                    Label("No date yet", systemImage: "clock.badge.questionmark")
                        .foregroundStyle(.orange)
                }
                if !draft.location.isEmpty {
                    Label(draft.location, systemImage: "mappin.and.ellipse")
                }
                if !draft.meetingLink.isEmpty {
                    Label(draft.meetingLink, systemImage: "video")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if !draft.details.isEmpty {
                    Label(draft.details, systemImage: "text.alignleft")
                        .lineLimit(4)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)

            HStack(spacing: 10) {
                Button(action: onAdd) {
                    Label("Add", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!draft.isReady)
                .accessibilityIdentifier("appointmentChat.add")

                Button("Edit", action: onEdit)
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .tint(Theme.accent)
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var whenText: String? {
        guard let date = draft.date else { return nil }
        guard draft.hasTime else {
            return date.formatted(.dateTime.weekday(.abbreviated).day().month().year()) + " · All day"
        }
        var text = date.formatted(.dateTime.weekday(.abbreviated).day().month().hour().minute())
        if let end = draft.end { text += " – " + end.formatted(date: .omitted, time: .shortened) }
        return text
    }
}

// MARK: - Screenshot reading

/// On-device text recognition (Vision) for pasted or picked screenshots.
private enum TextRecognizer {
    static func text(in image: UIImage) async -> String {
        guard let cgImage = image.cgImage else { return "" }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        return await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
            do { try handler.perform([request]) } catch { return "" }
            return (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        }.value
    }
}

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

private extension NSItemProvider {
    func loadImage() async -> UIImage? {
        await withCheckedContinuation { cont in
            _ = loadObject(ofClass: UIImage.self) { object, _ in
                cont.resume(returning: object as? UIImage)
            }
        }
    }

    func loadText() async -> String? {
        await withCheckedContinuation { cont in
            _ = loadObject(ofClass: NSString.self) { object, _ in
                cont.resume(returning: (object as? NSString).map { String($0) })
            }
        }
    }
}

#Preview {
    AppointmentChatView()
        .modelContainer(for: PlannerItem.self, inMemory: true)
}
