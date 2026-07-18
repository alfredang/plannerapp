import SwiftUI
import SwiftData

/// The right-hand pane for a sidebar list category or user list: the filtered
/// to-dos/appointments on top, and a chatbot-style capture bar pinned to the bottom — type or
/// dictate what you need to do and the on-device assistant drafts and saves the entry,
/// replying inline like a chat. Entries captured while a user list is open join that list.
struct MacPlannerPane: View {
    let selection: SidebarSelection

    @Environment(\.modelContext) private var context

    @Query(
        filter: #Predicate<PlannerItem> { !$0.isArchived },
        sort: [SortDescriptor(\PlannerItem.date), SortDescriptor(\PlannerItem.createdAt, order: .reverse)]
    )
    private var activeItems: [PlannerItem]

    @Query(sort: \PlannerList.createdAt)
    private var lists: [PlannerList]

    /// Who "I" am, for the assigned-to filter (shared with the iPhone app's key).
    @AppStorage("ownerName") private var ownerName = "Alfred"

    // Created lazily on first mic click so the permission prompt is contextual, never at launch.
    @State private var speech: SpeechRecognizer?
    @State private var input = ""
    @State private var isThinking = false
    @State private var lastReply: ChatMessage?
    @State private var showingAdd = false
    @State private var editingItem: PlannerItem?
    /// Keyword filter over active items (archived items are never searched).
    @State private var searchText = ""
    @FocusState private var inputFocused: Bool

    private var isListening: Bool { speech?.isListening ?? false }

    /// The open user list, when the selection is one.
    private var currentList: PlannerList? {
        guard case .userList(let id) = selection else { return nil }
        return lists.first { $0.id == id }
    }

    private var title: String {
        switch selection {
        case .category(let c): return c.title
        case .userList:        return currentList?.name ?? "List"
        }
    }

    private var items: [PlannerItem] {
        // A search looks across every active list, not just the current view — otherwise
        // you'd have to know which list something is in before you could find it.
        // Archived items are never included (`activeItems` already excludes them).
        if isSearching { return searchResults }

        let scoped: [PlannerItem]
        switch selection {
        case .category(let c):
            // Smart views are *your* queue: your own items (unassigned, or assigned to
            // you) only. Work delegated to someone else is hidden here — open that
            // person's list to see theirs. Matches the iPhone app.
            scoped = activeItems.filter { c.contains($0) && $0.isMine(ownerName: ownerName) }
        case .userList:
            // A parent list shows its own items plus everything in its sub-lists.
            let ids = currentList?.subtreeIDs ?? []
            scoped = activeItems.filter { item in
                guard let listID = item.list?.id else { return false }
                return ids.contains(listID)
            }
        }
        return scoped
    }

    private var searchResults: [PlannerItem] {
        activeItems.filter { $0.matches(searchText) }
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Rows in manual drag order (synced via CloudKit through `PlannerItem.sortOrder`),
    /// pinned rows first; never-placed rows keep their date order, after the placed ones.
    private var tasks: [PlannerItem] {
        ManualOrder.sortedPinnedFirst(items.filter { $0.kind == .task },
                                      pinned: { $0.isPinned }, position: { $0.sortOrder })
    }
    private var appointments: [PlannerItem] {
        ManualOrder.sortedPinnedFirst(items.filter { $0.kind == .appointment },
                                      pinned: { $0.isPinned }, position: { $0.sortOrder })
    }

    private func moveItems(_ ordered: [PlannerItem], from source: IndexSet, to destination: Int) {
        ManualOrder.applyMove(ordered, from: source, to: destination) { item, position in
            item.sortOrder = position
        }
    }

    private var subtitle: String {
        let n = items.count
        let noun = "item\(n == 1 ? "" : "s")"
        return isSearching ? "\(n) \(noun) matching “\(searchText)”" : "\(n) \(noun)"
    }

    /// Keyword search over every active item — titles, notes, assignee and list name.
    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            TextField("Search to-dos and appointments", text: $searchText)
                .textFieldStyle(.plain)
                .font(.body)
                .onSubmit { }
            if isSearching {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            if items.isEmpty {
                emptyState
            } else {
                itemList
            }
            Divider()
            captureBar
        }
        .navigationTitle(isSearching ? "Search" : title)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingAdd = true } label: {
                    Image(systemName: "plus")
                }
                .help("New item")
                .accessibilityLabel("Add item")
            }
        }
        .sheet(isPresented: $showingAdd) { AddItemView(defaultList: currentList) }
        .sheet(item: $editingItem) { AddItemView(item: $0) }
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

    // MARK: - Item list

    private var itemList: some View {
        List {
            if !appointments.isEmpty {
                let ordered = appointments
                Section("Appointments") {
                    ForEach(ordered) { row($0) }
                        .onMove { moveItems(ordered, from: $0, to: $1) }
                }
            }
            if !tasks.isEmpty {
                let ordered = tasks
                Section("To-Do") {
                    ForEach(ordered) { row($0) }
                        .onMove { moveItems(ordered, from: $0, to: $1) }
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func row(_ item: PlannerItem) -> some View {
        HStack(spacing: 10) {
            ItemRow(item: item) {
                withAnimation { item.toggleDone() }   // checking auto-archives
            } onEdit: {
                editingItem = item
            }
            // Click the pin to pin/unpin — solid orange when pinned, faint outline when not.
            Button {
                withAnimation { item.isPinned.toggle() }
            } label: {
                Image(systemName: item.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11))
                    .foregroundStyle(item.isPinned ? AnyShapeStyle(.orange)
                                                   : AnyShapeStyle(.secondary.opacity(0.5)))
            }
            .buttonStyle(.plain)
            .help(item.isPinned ? "Unpin" : "Pin to top")
            .accessibilityLabel(item.isPinned ? "Unpin" : "Pin to top")
            // Drag affordance — the whole row drags, the grip just signals it.
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
                .help("Hold and drag to rearrange")
                .accessibilityHidden(true)
        }
        .contextMenu {
            Button(item.isPinned ? "Unpin" : "Pin to Top") {
                withAnimation { item.isPinned.toggle() }
            }
            Button("Edit…") { editingItem = item }
            Divider()
            Button("Delete", role: .destructive) { context.delete(item) }
        }
    }

    private var emptyState: some View {
        Group {
            if isSearching {
                ContentUnavailableView {
                    Label("No matches", systemImage: "magnifyingglass")
                } description: {
                    Text("Nothing active matches “\(searchText)”. Archived items aren't searched.")
                }
            } else {
                ContentUnavailableView {
                    Label("Nothing planned yet", systemImage: "sparkles")
                } description: {
                    Text("Tell the assistant below what you need to do — type it or click the mic.")
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Chatbot capture bar

    private var captureBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isThinking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Drafting…").font(.footnote).foregroundStyle(.secondary)
                }
            } else if let reply = lastReply {
                assistantBubble(reply)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(spacing: 10) {
                TextField(isListening ? "Listening…" : "e.g. “Lunch with Sam tomorrow 1pm”",
                          text: $input, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Theme.card, in: Capsule())
                    .focused($inputFocused)
                    .onSubmit(send)

                Button {
                    // Construct the recognizer lazily; ask permission on first mic use only.
                    let recognizer = speech ?? SpeechRecognizer()
                    if speech == nil { speech = recognizer }
                    Task {
                        await recognizer.requestAuthorization()
                        withAnimation { recognizer.toggle() }
                    }
                } label: {
                    Image(systemName: isListening ? "stop.fill" : "mic.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(isListening ? Color.red : Theme.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .help(isListening ? "Stop dictation" : "Add by voice")
                .accessibilityLabel(isListening ? "Stop dictation" : "Dictate")

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(canSend ? Theme.accent : Color.secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("Send")
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func assistantBubble(_ message: ChatMessage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(Theme.accent)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(message.text)
                if let item = message.item {
                    HStack(spacing: 8) {
                        Label(item.kind.title, systemImage: item.kind.symbol)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                        if let date = item.date {
                            Label(date.formatted(.dateTime.weekday().month().day().hour().minute()),
                                  systemImage: "clock")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button("Undo") { undo(item.id) }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.link)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isThinking
    }

    // MARK: - Actions

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isThinking else { return }
        speech?.stop()
        input = ""
        isThinking = true

        Task {
            let draft = await IntentAssistant.draft(from: text)
            var saved: PlannerItem?
            if !draft.entry.title.isEmpty {
                let item = draft.entry.makeItem()
                item.list = currentList   // capture into the open user list, if any
                context.insert(item)
                saved = item
            }
            withAnimation {
                lastReply = ChatMessage(role: .assistant,
                                        text: draft.reply,
                                        item: saved.map(ChatMessage.ItemSummary.init))
                isThinking = false
            }
        }
    }

    private func undo(_ itemID: UUID) {
        guard let item = try? context.fetch(FetchDescriptor<PlannerItem>()).first(where: { $0.id == itemID })
        else { return }
        context.delete(item)
        withAnimation {
            lastReply = ChatMessage(role: .assistant, text: "Removed “\(item.title)”.")
        }
    }
}

#Preview {
    NavigationStack {
        MacPlannerPane(selection: .category(.all))
    }
    .modelContainer(for: PlannerItem.self, inMemory: true)
}
