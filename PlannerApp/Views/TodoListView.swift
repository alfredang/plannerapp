import SwiftUI
import SwiftData

/// The main planner screen, aligned with the Mac desktop layout: the same smart categories
/// (All Items, Today, Scheduled, To-Dos, Appointments) plus the user's own lists, shown as a
/// visible chip bar. Tap a chip to filter; long-press a list chip to rename or delete it;
/// "＋ New List" creates one. Includes the **voice add** mic button and a manual add button.
struct TodoListView: View {
    /// Which kind this tab shows — Appointments and To-Dos are separate tabs, so a page
    /// never mixes both sections.
    var mode: PlannerKind = .task

    @Environment(\.modelContext) private var context

    // Active items only; checked items auto-archive and disappear from here.
    @Query(
        filter: #Predicate<PlannerItem> { !$0.isArchived },
        sort: [SortDescriptor(\PlannerItem.date), SortDescriptor(\PlannerItem.createdAt, order: .reverse)]
    )
    private var items: [PlannerItem]

    @Query(sort: \PlannerList.createdAt) private var lists: [PlannerList]

    @Environment(\.undoManager) private var undoManager

    @State private var filter: PlannerFilter = .category(.all)
    @State private var showingAdd = false
    @State private var showingLists = false

    // Chatbot capture bar (mirrors the Mac pane): type or dictate, the assistant drafts
    // and saves the entry, replying inline with Undo.
    @State private var speech: SpeechRecognizer?
    @State private var input = ""
    @State private var isThinking = false
    @State private var lastReply: ChatMessage?
    @FocusState private var inputFocused: Bool

    private var isListening: Bool { speech?.isListening ?? false }
    @State private var editingItem: PlannerItem?
    /// Item the user tapped "Undo" on — held until they confirm the delete.
    @State private var pendingUndo: UUID?

    /// Who "I" am, for the assigned-to filter. Items assigned to this name (or to nobody)
    /// stay in the smart views; anything delegated to someone else is filtered out.
    @AppStorage("ownerName") private var ownerName = "Alfred"

    /// The open user list, when the filter is one.
    private var currentList: PlannerList? {
        guard case .list(let id) = filter else { return nil }
        return lists.first { $0.id == id }
    }

    private var modeTitle: String { mode == .task ? "To-Dos" : "Appointments" }

    private var navigationTitle: String {
        if case .list = filter, let list = currentList { return list.name }
        return modeTitle
    }

    /// Everything of this tab's kind (the tab never mixes to-dos and appointments).
    private var kindItems: [PlannerItem] { items.filter { $0.kind == mode } }

    private var visibleItems: [PlannerItem] {
        switch filter {
        case .category(let c):
            // Smart views are *your* queue: your own items (unassigned, or assigned to
            // you) only. Work delegated to someone else is hidden here so it doesn't
            // drown out yours — open that person's list to see theirs.
            return kindItems.filter { c.contains($0) && $0.isMine(ownerName: ownerName) }
        case .list:
            // A parent list shows its own items plus everything in its sub-lists —
            // including assigned ones, since that's the point of opening someone's list.
            let ids = currentList?.subtreeIDs ?? []
            return kindItems.filter { item in
                guard let listID = item.list?.id else { return false }
                return ids.contains(listID)
            }
        }
    }

    /// Rows in manual drag order (synced via CloudKit through `sortOrder`, so the Mac app
    /// shows the same arrangement); never-placed rows keep their date order, after the
    /// placed ones. Same for the list chips below.
    /// Visible rows in manual drag order, pinned first.
    private var rows: [PlannerItem] {
        ManualOrder.sortedPinnedFirst(visibleItems,
                                      pinned: { $0.isPinned }, position: { $0.sortOrder })
    }
    private func moveItems(_ ordered: [PlannerItem], from source: IndexSet, to destination: Int) {
        ManualOrder.applyMove(ordered, from: source, to: destination) { item, position in
            item.sortOrder = position
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                chipBar
                Divider()
                if visibleItems.isEmpty {
                    emptyState
                } else {
                    itemList
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingLists = true } label: {
                        Image(systemName: "folder.badge.gearshape")
                    }
                    .accessibilityLabel("Manage lists")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { withAnimation { undoManager?.undo() } } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .disabled(!(undoManager?.canUndo ?? false))
                    .accessibilityLabel("Undo")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAdd = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add item")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { captureBar }
            .sheet(isPresented: $showingAdd) {
                // Default the form to this tab's kind.
                AddItemView(prefill: ParsedEntry(title: "", kind: mode, date: nil),
                            defaultList: currentList)
            }
            .sheet(isPresented: $showingLists) { ListsManagerView() }
            .sheet(item: $editingItem) { AddItemView(item: $0) }
            .confirmationDialog("Remove this entry?",
                                isPresented: Binding(get: { pendingUndo != nil },
                                                     set: { if !$0 { pendingUndo = nil } }),
                                titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    if let id = pendingUndo { undoCapture(id) }
                    pendingUndo = nil
                }
                Button("Keep", role: .cancel) { pendingUndo = nil }
            } message: {
                Text("This deletes the entry the assistant just saved.")
            }
            .onChange(of: lists.count) {
                // If the selected list was deleted (locally or via sync), fall back to All.
                if case .list(let id) = filter, !lists.contains(where: { $0.id == id }) {
                    filter = .category(.all)
                }
            }
        }
    }

    // MARK: - Chip bar (mirrors the Mac sidebar: smart categories, then My Lists)

    private var chipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Just the three smart views — All, Pinned, Today. The user's lists live
                // behind the folder button in the toolbar (tap a folder to open it).
                // Same smart views as the Mac sidebar (Appointments/To-Dos are tabs here).
                ForEach([PlannerCategory.all, .pinned, .today, .scheduled]) { category in
                    chip(title: category.title(for: mode),
                         symbol: category.symbol,
                         // Same rule as `visibleItems`, so the badge matches the rows.
                         count: kindItems.filter { category.contains($0) && $0.isMine(ownerName: ownerName) }.count,
                         isSelected: filter == .category(category)) {
                        withAnimation { filter = .category(category) }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Theme.bg)
    }

    private func chip(title: String, symbol: String, count: Int,
                      isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.caption)
                Text(title)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                }
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isSelected ? Theme.accent : Theme.card, in: Capsule())
            .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Items

    private var itemList: some View {
        List {
            let ordered = rows
            ForEach(ordered) { row($0) }
                .onDelete { delete(ordered, at: $0) }
                .onMove { moveItems(ordered, from: $0, to: $1) }
        }
    }

    private func row(_ item: PlannerItem) -> some View {
        HStack(spacing: 10) {
            ItemRow(item: item) {
                withAnimation { item.toggleDone() }   // checking auto-archives
            } onEdit: {
                editingItem = item
            }
            // Tap the pin to pin/unpin — solid orange when pinned, faint outline when not.
            Button {
                withAnimation { item.isPinned.toggle() }
            } label: {
                Image(systemName: item.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 15))
                    .foregroundStyle(item.isPinned ? AnyShapeStyle(.orange)
                                                   : AnyShapeStyle(.secondary.opacity(0.5)))
                    .frame(width: 28, height: 28)   // comfortable tap target
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(item.isPinned ? "Unpin" : "Pin to top")
            // Drag affordance — hold and drag anywhere on the row to rearrange.
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                withAnimation { item.isPinned.toggle() }
            } label: {
                Label(item.isPinned ? "Unpin" : "Pin",
                      systemImage: item.isPinned ? "pin.slash.fill" : "pin.fill")
            }
            .tint(.orange)
        }
    }

    // MARK: - Chatbot capture bar (mirrors the Mac pane, pinned to the bottom)

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
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(isListening ? Color.red : Theme.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isListening ? "Stop dictation" : "Dictate")

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(canSend ? Theme.accent : Color.secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
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

    private func assistantBubble(_ message: ChatMessage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(Theme.accent)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(message.text)
                    .font(.subheadline)
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
                        // Destructive: confirm first. This button sits right above the
                        // capture bar, so an accidental tap used to delete the entry
                        // silently.
                        Button("Undo", role: .destructive) { pendingUndo = item.id }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.borderless)
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
                item.list = currentList   // capture into the open list, if any
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

    private func undoCapture(_ itemID: UUID) {
        guard let item = try? context.fetch(FetchDescriptor<PlannerItem>()).first(where: { $0.id == itemID })
        else { return }
        context.delete(item)
        withAnimation {
            lastReply = ChatMessage(role: .assistant, text: "Removed “\(item.title)”.")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: "sparkles")
        } description: {
            Text(mode == .task
                 ? "Tap + to add a to-do, or tell the assistant below what you need to do."
                 : "Tap + to add an appointment, or tell the assistant below — e.g. “Lunch with Sam tomorrow 1pm”.")
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyTitle: String {
        if let list = currentList { return "No \(modeTitle.lowercased()) in “\(list.name)”" }
        if case .category(let c) = filter, c != .all { return "Nothing in \(c.title)" }
        return mode == .task ? "No to-dos yet" : "No appointments yet"
    }

    // MARK: - List management

    private func delete(_ source: [PlannerItem], at offsets: IndexSet) {
        for index in offsets { context.delete(source[index]) }
    }
}

#Preview {
    TodoListView()
        .modelContainer(for: PlannerItem.self, inMemory: true)
}
