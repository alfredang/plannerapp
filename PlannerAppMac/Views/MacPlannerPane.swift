import SwiftUI
import SwiftData

/// The right-hand pane for a sidebar list category or user list: the filtered
/// to-dos/appointments on top, and a chatbot-style capture bar pinned to the bottom — type or
/// dictate what you need to do and the on-device assistant drafts and saves the entry,
/// replying inline like a chat. Entries captured while a user list is open join that list.
struct MacPlannerPane: View {
    let selection: SidebarSelection
    /// Opens another user list (org-chart clicks on an agent).
    var onOpenList: ((UUID) -> Void)? = nil
    var onOpenAgent: ((String) -> Void)? = nil

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
    /// The assistant's answer to an edit or a miss, shown briefly above the bar.
    @State private var reply: String?
    @State private var showingAdd = false
    @State private var editingItem: PlannerItem?
    @State private var deletingItem: PlannerItem?
    /// Keyword filter over active items (archived items are never searched).
    @State private var searchText = ""
    @FocusState private var inputFocused: Bool

    private var isListening: Bool { speech?.isListening ?? false }

    // Digital Workforce: lists named after an agent in ~/.claude/agents show its profile; a list
    // of such lists shows the org chart. Items stay one click away on the To-Dos tab.
    @State private var roster: [String: AgentProfile] = [:]
    @State private var agentJobs: [ScheduledJob] = []
    @AppStorage("agentPaneShowsItems") private var agentShowsItems = false
    @State private var agentShowsChat = false

    /// The agent behind the open list, if it's named after one.
    private var currentAgent: AgentProfile? {
        if case .digitalStaff(let id) = selection { return roster[id] }
        return currentList.flatMap { roster[$0.name.lowercased()] }
    }

    /// The open list groups agent lists (e.g. "Digital Workforce").
    private var isWorkforceGroup: Bool {
        guard currentAgent == nil, let list = currentList else { return false }
        return list.name.caseInsensitiveCompare("Digital Workforce") == .orderedSame
            || !OrgChartBuilder.agentChildren(of: list, roster: roster).isEmpty
    }

    /// The open list is the "Human Workforce" group: it shows the HR org chart built from the HRMS.
    private var isHumanWorkforce: Bool {
        guard currentAgent == nil, let list = currentList else { return false }
        return list.name.caseInsensitiveCompare("Human Workforce") == .orderedSame
    }

    /// The open list is "Trainers": it shows the Trainer Directory built from the LMS/TMS.
    private var isTrainers: Bool {
        guard currentAgent == nil, let list = currentList else { return false }
        return list.name.caseInsensitiveCompare("Trainers") == .orderedSame
    }

    /// A person's list (a staff member, intern or trainer) shows their overview page, like an agent's profile.
    private var personPage: URL? {
        guard currentAgent == nil, !isWorkforceGroup, !isHumanWorkforce, !isTrainers, let list = currentList else { return nil }
        return WorkspaceChartView.personPage(forList: list.name)
    }

    private var hasAgentView: Bool {
        currentAgent != nil || isWorkforceGroup || isHumanWorkforce || isTrainers || personPage != nil
    }
    private var showsCaptureBar: Bool {
        // The bar files to-dos and appointments, or on Goals and Ideas what gets researched.
        // Pages use + instead.
        if selection == .category(.pages) { return false }
        return !(hasAgentView && !isSearching && !agentShowsItems)
    }

    /// What + creates here: a goal on Goals, an idea on Ideas, a page on Pages, else the
    /// form's default.
    private var newItemKind: PlannerKind? {
        switch selection {
        case .category(.goals): return .goal
        case .category(.ideas): return .idea
        case .category(.pages): return .page
        default:                return nil
        }
    }

    /// What the capture bar files when it isn't the assistant: the researched kinds.
    private var researchedCaptureKind: PlannerKind? {
        newItemKind.flatMap { $0 == .goal || $0 == .idea ? $0 : nil }
    }

    private var capturePlaceholder: String {
        if isListening { return "Listening…" }
        switch researchedCaptureKind {
        case .goal: return "Say your goal, e.g. “More than 5 franchisees by 2027”. Nova turns it into a researched page."
        case .idea: return "Say your idea. Nova turns it into a researched page."
        default:    return "e.g. “Lunch with Sam tomorrow 1pm”"
        }
    }

    private func jobs(for agent: AgentProfile) -> [ScheduledJob] {
        agentJobs.filter { $0.detail?.lowercased() == agent.id }
    }

    /// Team chart: principal → agent lists above this one → this agent → its sub-agents.
    private func teamChart(for agent: AgentProfile, list: PlannerList?) -> OrgNode {
        if AgentRoster.staffIDs.contains(agent.id),
           let group = lists.first(where: { $0.name.caseInsensitiveCompare("Digital Workforce") == .orderedSame }) {
            let nodes = OrgChartBuilder.staff(of: group, roster: roster).map { member in
                OrgChartBuilder.node(for: member.profile, list: lists.first { $0.id == member.listID },
                                     roster: roster, focus: agent.id)
            }
            return OrgChartBuilder.workforce(fallback: ownerName, nodes: nodes)
        }
        var team = OrgChartBuilder.node(for: agent, list: list, roster: roster, focus: agent.id)
        let reportingLines = AgentRoster.reportingLines
        if reportingLines.values.contains(agent.id), let group = list?.parent,
           group.name.caseInsensitiveCompare("Digital Workforce") == .orderedSame {
            team.children = OrgChartBuilder.staff(of: group, roster: roster)
                .filter { reportingLines[$0.profile.id] == agent.id }
                .map { member in OrgChartBuilder.node(for: member.profile, list: lists.first { $0.id == member.listID }, roster: roster) }
            return OrgChartBuilder.principalNode(fallback: ownerName, children: [team])
        }
        if AgentRoster.staffIDs.contains(agent.id), let leadID = reportingLines[agent.id], let lead = roster[leadID] {
            var boss = OrgChartBuilder.node(for: lead, list: nil, roster: [:])
            boss.listID = lists.first { $0.name.caseInsensitiveCompare(lead.displayName) == .orderedSame }?.id
            boss.children = [team]
            return OrgChartBuilder.principalNode(fallback: ownerName, children: [boss])
        }
        var parent = list?.parent
        while let p = parent, let boss = roster[p.name.lowercased()] {
            var node = OrgChartBuilder.node(for: boss, list: nil, roster: [:])
            node.listID = p.id
            node.children = [team]
            team = node
            parent = p.parent
        }
        return OrgChartBuilder.principalNode(fallback: ownerName, children: [team])
    }

    @ViewBuilder
    private var agentContent: some View {
        if let agent = currentAgent {
            AgentProfileView(agent: agent,
                             team: teamChart(for: agent, list: currentList),
                             jobs: jobs(for: agent), onOpenList: onOpenList,
                             onOpenChat: { agentShowsItems = false; agentShowsChat = true })
        } else if isHumanWorkforce {
            WorkspaceChartView.humanWorkforce
        } else if isTrainers {
            WorkspaceChartView.trainers
        } else if let page = personPage, let list = currentList {
            WorkspaceChartView(fileURL: page, windowTitle: list.name, emptyTitle: "No overview yet",
                               emptyHint: "Vesta builds it from the HRMS and the LMS/TMS.")
                .id(page)
        } else if let list = currentList {
            let members = OrgChartBuilder.staff(of: list, roster: roster)
            let nodes = members.map { member in
                OrgChartBuilder.node(for: member.profile, list: lists.first { $0.id == member.listID }, roster: roster)
            }
            DigitalWorkforceArtifactView(
                chart: OrgChartBuilder.workforce(fallback: ownerName, nodes: nodes),
                jobs: agentJobs,
                onOpenAgent: { onOpenAgent?($0) })
        }
    }

    private var agentModeBar: some View {
        Picker("View", selection: Binding<Int>(
            get: { agentShowsChat && currentAgent != nil ? 2 : (agentShowsItems ? 1 : 0) },
            set: { agentShowsChat = $0 == 2; agentShowsItems = $0 == 1 }
        )) {
            Text(currentAgent != nil ? "Profile" : (isTrainers ? "Directory" : (personPage != nil ? "Overview" : "Org Chart"))).tag(0)
            if currentAgent != nil { Text("Chat").tag(2) }
            Text("To-Dos (\(items.count))").tag(1)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: currentAgent != nil ? 380 : 280)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
    }

    /// The open user list, when the selection is one.
    private var currentList: PlannerList? {
        if case .digitalStaff(let id) = selection {
            return lists.first { $0.name.lowercased() == id }
        }
        guard case .userList(let id) = selection else { return nil }
        return lists.first { $0.id == id }
    }

    private var title: String {
        switch selection {
        case .category(let c): return c.title
        case .userList:        return currentList?.name ?? "List"
        case .digitalStaff(let id): return currentAgent?.displayName ?? id.capitalized
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
        case .userList, .digitalStaff:
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
    /// To-dos: by priority (Critical → Low), pinned first within a priority, then manual order.
    private var tasks: [PlannerItem] {
        ManualOrder.sortedPinnedByPriority(items.filter { $0.kind == .task },
                                           pinned: { $0.isPinned },
                                           priority: { $0.priorityRaw },
                                           position: { $0.sortOrder })
    }
    private var appointments: [PlannerItem] {
        ManualOrder.sortedPinnedFirst(items.filter { $0.kind == .appointment },
                                      pinned: { $0.isPinned }, position: { $0.sortOrder })
    }
    /// Pages (HTML content): pinned first, then manual order, then by title and list — every
    /// client's page is called "Client Overview", so the list (client) name breaks the tie.
    private var pages: [PlannerItem] {
        let byName = items.filter { $0.kind == .page }.sorted {
            ($0.title + " " + ($0.list?.name ?? ""))
                .localizedStandardCompare($1.title + " " + ($1.list?.name ?? "")) == .orderedAscending
        }
        return ManualOrder.sortedPinnedFirst(byName, pinned: { $0.isPinned },
                                             position: { $0.sortOrder })
    }

    /// Goals still being worked towards: nearest target first, then manual order.
    private var openGoals: [PlannerItem] {
        let byTarget = items.filter { $0.isGoal && !$0.isDone }
            .sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
        return ManualOrder.sortedPinnedFirst(byTarget, pinned: { $0.isPinned },
                                             position: { $0.sortOrder })
    }
    /// Achieved goals, most recent first — kept on the list as a record.
    private var achievedGoals: [PlannerItem] {
        items.filter { $0.isGoal && $0.isDone }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    /// Ideas: newest first, then manual order.
    private var ideas: [PlannerItem] {
        let newest = items.filter(\.isIdea).sorted { $0.createdAt > $1.createdAt }
        return ManualOrder.sortedPinnedFirst(newest, pinned: { $0.isPinned },
                                             position: { $0.sortOrder })
    }

    private func moveItems(_ ordered: [PlannerItem], from source: IndexSet, to destination: Int) {
        ManualOrder.applyMove(ordered, from: source, to: destination) { item, position in
            item.sortOrder = position
        }
    }

    private var subtitle: String {
        let n = items.count
        let noun = (researchedCaptureKind != nil && !isSearching ? "page" : "item") + (n == 1 ? "" : "s")
        return isSearching ? "\(n) \(noun) matching “\(searchText)”" : "\(n) \(noun)"
    }

    /// Keyword search over every active item — titles, notes, assignee and list name.
    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            TextField("Search to-dos, appointments and pages", text: $searchText)
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

    /// Same-list-same-title-same-day clusters among the rows on screen (multi-day courses are not
    /// duplicates and are never flagged — see DuplicateAudit).
    private var duplicateGroups: [DuplicateAudit.Group] {
        DuplicateAudit.findDuplicates(in: items)
    }

    /// Quiet banner offering to archive redundant copies. Only appears when there are any.
    @ViewBuilder
    private var duplicateBanner: some View {
        let groups = duplicateGroups
        if !groups.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(groups.count == 1
                         ? "1 possible duplicate"
                         : "\(groups.count) possible duplicates")
                        .font(.callout.weight(.medium))
                    Text(groups.map { "“\($0.title)” (\($0.dayLabel))" }
                            .joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Button("Archive extras") {
                    withAnimation { groups.forEach(DuplicateAudit.resolve) }
                }
                .help("Keeps the original of each and archives the later copies — nothing is deleted")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.12))
            Divider()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !agentShowsChat || currentAgent == nil {
                searchBar
                Divider()
            }
            duplicateBanner
            if hasAgentView && !isSearching {
                agentModeBar
                Divider()
            }
            if let agent = currentAgent, agentShowsChat && !isSearching {
                MacAgentChatView(agent: agent).id(agent.id)
                    .frame(maxHeight: .infinity)
            } else if hasAgentView && !isSearching && !agentShowsItems {
                agentContent
                    .frame(maxHeight: .infinity)
            } else if items.isEmpty {
                emptyState
            } else if researchedCaptureKind != nil && !isSearching {
                // Goals and Ideas are read, not ticked off: each one is its page.
                MacResearchPagesView(items: openGoals + achievedGoals + ideas,
                                     onEdit: { editingItem = $0 },
                                     onDelete: { deletingItem = $0 })
                    .frame(maxHeight: .infinity)
            } else {
                itemList
            }
            if showsCaptureBar {
                Divider()
                captureBar
            }
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
        .task(id: selection) {
            if case .digitalStaff = selection {
                searchText = ""
                agentShowsItems = false
                agentShowsChat = true
            } else {
                agentShowsChat = false
                if isWorkforceGroup { searchText = "" }
            }
            // Re-read on every list switch so edits to the agent .md files show up — off the
            // main thread (files + `launchctl`), so the click itself never waits on them.
            let loaded = await Task.detached(priority: .userInitiated) { AgentRoster.load() }.value
            guard !Task.isCancelled else { return }
            if loaded != roster {
                roster = loaded
                if isWorkforceGroup { searchText = "" }
            }
            if hasAgentView {
                let jobs = await Task.detached(priority: .userInitiated) { ScheduleLoader.workforce() }.value
                guard !Task.isCancelled else { return }
                agentJobs = jobs
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddItemView(prefill: newItemKind.map { ParsedEntry(title: "", kind: $0, date: nil) },
                        defaultList: currentList,
                        onSave: { ItemResearcher.shared.sweep() })
        }
        .sheet(item: $editingItem) { AddItemView(item: $0) }
        .confirmationDialog("Delete this item?", isPresented: .init(
            get: { deletingItem != nil },
            set: { if !$0 { deletingItem = nil } }
        ), presenting: deletingItem) { item in
            Button("Delete", role: .destructive) {
                withAnimation { context.delete(item) }
                deletingItem = nil
            }
            Button("Cancel", role: .cancel) { deletingItem = nil }
        } message: { item in
            Text("“\(item.title)” will be removed permanently.")
        }
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

    /// Upcoming is broken down by date instead of by kind (search results stay flat).
    private var showsDaySections: Bool {
        (selection == .category(.appointments) || selection == .category(.scheduled)) && !isSearching
    }

    private var itemList: some View {
        List {
            if showsDaySections {
                // Date order is the point here, so there's no drag-to-rearrange.
                // Appointments (which absorbed Upcoming): past ones not yet ticked are
                // "Earlier", not overdue — they wait for "Did this happen?".
                let pastTitle = selection == .category(.appointments) ? "Earlier" : "Overdue"
                ForEach(DaySections.group(items, pastTitle: pastTitle)) { section in
                    Section(section.title) {
                        ForEach(section.items) { row($0) }
                    }
                }
            } else {
                kindSections
            }
        }
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var kindSections: some View {
        if !openGoals.isEmpty {
            let ordered = openGoals
            Section("Goals") {
                ForEach(ordered) { row($0) }
                    .onMove { moveItems(ordered, from: $0, to: $1) }
            }
        }
        if !achievedGoals.isEmpty {
            Section("Achieved") {
                ForEach(achievedGoals) { row($0) }
            }
        }
        if !ideas.isEmpty {
            let ordered = ideas
            Section("Ideas") {
                ForEach(ordered) { row($0) }
                    .onMove { moveItems(ordered, from: $0, to: $1) }
            }
        }
        // Pages lead the rest: in a client's list the overview is the main document.
        if !pages.isEmpty {
            let ordered = pages
            Section("Pages") {
                ForEach(ordered) { row($0) }
                    .onMove { moveItems(ordered, from: $0, to: $1) }
            }
        }
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

    private func row(_ item: PlannerItem) -> some View {
        HStack(spacing: 10) {
            // Clicking the item shows it as a page (its report, or the item rendered as HTML);
            // the pencil button edits it.
            ItemRow(item: item) {
                withAnimation { item.toggleDone() }   // checking auto-archives
            } onEdit: {
                editingItem = item
            } onOpen: {
                ItemPageViewer.open(item)
            }
            // Where a goal's or idea's research has got to.
            if item.isResearched {
                ResearchStatusBadge(item: item)
            }
            // Priority flag on to-dos: click to set Critical / High / Medium / Low.
            if item.kind == .task {
                PriorityMenuButton(item: item, size: 11)
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
            Button {
                editingItem = item
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .help("Edit")
            .accessibilityLabel("Edit")
            // Deleting is permanent, so the click asks first.
            Button {
                deletingItem = item
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.red.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help("Delete")
            .accessibilityLabel("Delete")
        }
        // Drag a row onto a sidebar list to move it there. Uses .onDrag with an
        // NSItemProvider rather than .draggable: inside a List(selection:) the
        // row is already a drag source for selection, which swallows .draggable.
        .onDrag {
            NSItemProvider(object: PlannerItemDragPayload(id: item.id))
        } preview: {
            Label(item.title, systemImage: item.kind.symbol)
                .padding(6)
        }
        .contextMenu {
            if item.kind == .task {
                Menu("Priority") {
                    PriorityMenuItems(item: item)
                }
            }
            Button(item.isPinned ? "Unpin" : "Pin to Top") {
                withAnimation { item.isPinned.toggle() }
            }
            Button("Open") { ItemPageViewer.open(item) }
            Button("Edit…") { editingItem = item }
            if item.isResearched, !item.isDone {
                Button("Research Again") { ItemResearcher.shared.researchAgain(item) }
            }
            // Move between work and content: a to-do that is really a document, or back.
            if item.kind == .task {
                Button("Convert to Page") { withAnimation { item.makePage() } }
            } else if item.isPage {
                Button("Convert to To-Do") { withAnimation { item.kind = .task } }
            }
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
            } else if selection == .category(.goals) {
                ContentUnavailableView {
                    Label("No goals yet", systemImage: "target")
                } description: {
                    Text("Say or type a goal below — what the business should achieve, and by when. Nova reviews it and writes a page with market research, competitor analysis, features, recommendations, a strategy and steps to implement.")
                }
            } else if selection == .category(.ideas) {
                ContentUnavailableView {
                    Label("No ideas yet", systemImage: "lightbulb")
                } description: {
                    Text("Say or type an idea below. Nova reviews it and writes a page with market research, competitor analysis, features, recommendations, a strategy and steps to implement.")
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
            }
            if let reply, !isThinking {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                    Text(reply).font(.callout)
                    Spacer(minLength: 0)
                    Button { withAnimation { self.reply = nil } } label: {
                        Image(systemName: "xmark").font(.caption2.weight(.bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Dismiss")
                }
                .transition(.opacity)
            }
            // No per-add confirmation: the new row appearing in the list above IS the
            // feedback, and ⌘Z (Edit ▸ Undo) reverts it like any other change.

            HStack(spacing: 10) {
                TextField(capturePlaceholder, text: $input, axis: .vertical)
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

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isThinking
    }

    // MARK: - Actions

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isThinking else { return }
        speech?.stop()
        input = ""
        // A goal or idea is filed as said and researched; the row shows how that's going.
        if let kind = researchedCaptureKind {
            withAnimation {
                ItemResearcher.shared.add(text, kind: kind, list: currentList, context: context)
            }
            return
        }
        isThinking = true

        reply = nil

        Task {
            // Same router as the iPhone bar: new entries are added (into the open list and
            // its owner), "move X to 8pm" edits the existing item. Reverting is ⌘Z.
            let result = await PlannerCommand.handle(text, context: context,
                                                     ownerName: ownerName,
                                                     defaultList: currentList)
            await PlannerCommand.commit(result, context: context)
            withAnimation {
                isThinking = false
                if result.action != .add || !result.didMutate { reply = result.reply }
            }
            if let shown = reply {
                try? await Task.sleep(for: .seconds(6))
                if reply == shown { withAnimation { reply = nil } }
            }
        }
    }
}

/// Where a goal's or idea's research has got to, beside its row. Once the page exists this
/// shows nothing: the row's "Open page" takes over.
private struct ResearchStatusBadge: View {
    let item: PlannerItem

    private var researcher: ItemResearcher { .shared }

    var body: some View {
        switch researcher.status(of: item) {
        case .researching:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Researching…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("\(ItemResearcher.agentName) is researching this. It usually takes a few minutes.")
        case .queued:
            Text("Waiting for research")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Starts when a research slot is free.")
        case .failed:
            Button("Research failed. Try again") { researcher.researchAgain(item) }
                .buttonStyle(.link)
                .font(.caption)
                .help("Log: ~/DigitalWorkforce/logs/<date>-nova-research.log")
        case .unavailable:
            Text("Research unavailable")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Research needs the Digital Workforce agents on this Mac.")
        case nil:
            EmptyView()
        }
    }
}

#Preview {
    NavigationStack {
        MacPlannerPane(selection: .category(.all))
    }
    .modelContainer(for: PlannerItem.self, inMemory: true)
}
