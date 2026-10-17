import SwiftUI
import AppKit

// MARK: - Org tree

/// One box on the org chart: the principal, a Digital Workforce agent, or a helper sub-agent.
struct OrgNode: Identifiable {
    var id: String
    var name: String
    var title: String
    var initials: String
    var agent: AgentProfile?
    /// The Planner list behind this agent, when it has one — clicking opens it.
    var listID: UUID?
    var isFocus = false
    var children: [OrgNode] = []

    /// Distinct agents below this node — a reviewer shared by two directors counts once.
    var descendantIDs: Set<String> { children.reduce(into: Set<String>()) { $0.insert($1.id); $0.formUnion($1.descendantIDs) } }

    func path(to target: String) -> [OrgNode]? {
        if id == target { return [self] }
        for child in children {
            if let path = child.path(to: target) { return [self] + path }
        }
        return nil
    }
}

enum OrgChartBuilder {
    /// Include scheduled staff such as Nova even when they have no sidebar list yet.
    static func staff(of list: PlannerList, roster: [String: AgentProfile]) -> [(profile: AgentProfile, listID: UUID?)] {
        let lists = agentChildren(of: list, roster: roster)
        var members: [(profile: AgentProfile, listID: UUID?)] = lists.compactMap { child in
            roster[child.name.lowercased()].map { ($0, child.id) }
        }
        if list.name.caseInsensitiveCompare("Digital Workforce") == .orderedSame {
            let listed = Set(members.map { $0.profile.id })
            for id in AgentRoster.staffIDs where !listed.contains(id) {
                if let profile = roster[id] { members.append((profile, nil)) }
            }
        }
        return members
    }

    /// Match the reporting lines in COMPANY.md; Atlas leads the operational staff.
    static func workforce(fallback: String, nodes: [OrgNode]) -> OrgNode {
        guard var atlas = nodes.first(where: { $0.id == "atlas" }) else {
            return principalNode(fallback: fallback, children: nodes)
        }
        let direct = AgentRoster.principalReportIDs
        atlas.children = nodes.filter { !direct.contains($0.id) }
        let leaders = [atlas] + nodes.filter { $0.id != "atlas" && direct.contains($0.id) }
        return principalNode(fallback: fallback, children: leaders)
    }
    /// Agent lists directly under `list`, in sidebar order.
    static func agentChildren(of list: PlannerList, roster: [String: AgentProfile]) -> [PlannerList] {
        ManualOrder.sortedPinnedFirst(list.children ?? [], pinned: { $0.isPinned }, position: { $0.sortOrder })
            .filter { roster[$0.name.lowercased()] != nil }
    }

    /// An agent's node with its sub-agents: agent lists nested under its list, plus the agents
    /// its instructions delegate to.
    static func node(for agent: AgentProfile, list: PlannerList?, roster: [String: AgentProfile],
                     focus: String? = nil, visited: Set<String> = []) -> OrgNode {
        let visited = visited.union([agent.id])
        var children: [OrgNode] = []
        var seen = Set<String>()
        if let list {
            for child in agentChildren(of: list, roster: roster) {
                guard let profile = roster[child.name.lowercased()], !visited.contains(profile.id),
                      seen.insert(profile.id).inserted else { continue }
                children.append(node(for: profile, list: child, roster: roster, focus: focus, visited: visited))
            }
        }
        for id in agent.subagentIDs where !visited.contains(id) && seen.insert(id).inserted {
            if let profile = roster[id] {
                children.append(node(for: profile, list: nil, roster: roster, focus: focus, visited: visited))
            }
        }
        return OrgNode(id: agent.id, name: agent.displayName, title: agent.title, initials: agent.initials,
                       agent: agent, listID: list?.id, isFocus: agent.id == focus, children: children)
    }

    static func principalNode(fallback: String, children: [OrgNode]) -> OrgNode {
        let principal = AgentRoster.principal(fallback: fallback)
        let initials = principal.name.split(separator: " ").filter { $0.first?.isUppercase == true && $0 != "Dr" }
            .prefix(2).compactMap(\.first).map(String.init).joined()
        return OrgNode(id: "principal", name: principal.name, title: principal.title,
                       initials: initials.isEmpty ? "★" : initials, children: children)
    }
}

/// Deterministic avatar colour per agent.
private func avatarColor(_ key: String) -> Color {
    let palette: [Color] = [.indigo, .teal, .orange, .pink, .green, .blue, .purple, .brown, .mint, .red, .cyan]
    let sum = key.unicodeScalars.reduce(0) { $0 + Int($1.value) }
    return palette[sum % palette.count]
}

private struct Avatar: View {
    let initials: String
    let key: String
    var size: CGFloat = 36

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(avatarColor(key).gradient, in: Circle())
    }
}

// MARK: - Org chart view

/// Top-down org chart. Wide teams wrap into columns when their full tree cannot fit the pane.
struct OrgChartView: View {
    let root: OrgNode
    var verticalFrom = 2
    var onOpenList: ((UUID) -> Void)?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            // Measure the real tree width. Without this, SwiftUI can accept a compressed
            // proposal while drawing the first agents (Atlas and Mercury) off the left edge.
            tree.fixedSize(horizontal: true, vertical: false).padding(.vertical, 4)
            wrappedTree.padding(.vertical, 4)
        }
    }

    private var tree: some View {
        OrgSubtree(node: root, depth: 0, verticalFrom: verticalFrom, onOpenList: onOpenList)
    }

    private var wrappedTree: some View {
        VStack(spacing: 0) {
            OrgNodeCard(node: root, onOpenList: onOpenList)
            if !root.children.isEmpty {
                Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 1, height: 14)
                // The label applies to every wrapped row, preserving the reporting level.
                Text("Reports to \(root.name)")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.bottom, 8)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12,
                                            alignment: .top)], alignment: .leading, spacing: 16) {
                    ForEach(root.children) { child in
                        OrgSubtree(node: child, depth: 1, verticalFrom: 1, onOpenList: onOpenList)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct OrgSubtree: View {
    let node: OrgNode
    let depth: Int
    let verticalFrom: Int
    var onOpenList: ((UUID) -> Void)?

    private let line = Color.secondary.opacity(0.4)

    var body: some View {
        VStack(spacing: 0) {
            OrgNodeCard(node: node, onOpenList: onOpenList)
            if !node.children.isEmpty {
                if depth + 1 >= verticalFrom {
                    stacked
                } else {
                    spread
                }
            }
        }
    }

    /// Children side by side, joined by a horizontal bus.
    private var spread: some View {
        VStack(spacing: 0) {
            Rectangle().fill(line).frame(width: 1, height: 14)
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(node.children.enumerated()), id: \.element.id) { index, child in
                    OrgSubtree(node: child, depth: depth + 1, verticalFrom: verticalFrom, onOpenList: onOpenList)
                        .padding(.top, 14)
                        .padding(.horizontal, 4)
                        .overlay(alignment: .top) {
                            ZStack(alignment: .top) {
                                HStack(spacing: 0) {
                                    Rectangle().fill(index == 0 ? .clear : line).frame(height: 1)
                                    Rectangle().fill(index == node.children.count - 1 ? .clear : line).frame(height: 1)
                                }
                                Rectangle().fill(line).frame(width: 1, height: 14)
                            }
                        }
                }
            }
        }
    }

    /// Children as an indented list hanging off a vertical spine.
    private var stacked: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(node.children) { child in
                HStack(alignment: .center, spacing: 0) {
                    Rectangle().fill(line).frame(width: 8, height: 1)
                    OrgSubtree(node: child, depth: depth + 1, verticalFrom: verticalFrom, onOpenList: onOpenList)
                }
            }
        }
        .padding(.top, 8)
        .padding(.leading, 6)
        .overlay(alignment: .topLeading) {
            Rectangle().fill(line).frame(width: 1).padding(.leading, 6).padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OrgNodeCard: View {
    let node: OrgNode
    var onOpenList: ((UUID) -> Void)?
    @State private var showingDetail = false
    @State private var hovering = false

    var body: some View {
        Button {
            if let id = node.listID, !node.isFocus, let onOpenList { onOpenList(id) }
            else if node.agent != nil { showingDetail = true }
        } label: {
            VStack(spacing: 5) {
                Avatar(initials: node.initials, key: node.id, size: 34)
                Text(node.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(node.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity)
                if let agent = node.agent {
                    Text(agent.skills.isEmpty
                         ? (agent.tools.isEmpty ? "All tools" : agent.tools.joined(separator: ", "))
                         : "\(agent.skills.count) skills · \(agent.connectors.count) conn.")
                        .lineLimit(1)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(10)
            .frame(width: 118)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(node.isFocus ? Theme.accent : Color.primary.opacity(hovering ? 0.25 : 0.1),
                                  lineWidth: node.isFocus ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(node.listID != nil && !node.isFocus ? "Open \(node.name)" : node.title)
        .popover(isPresented: $showingDetail, arrowEdge: .bottom) {
            if let agent = node.agent {
                AgentSummaryPopover(agent: agent)
            }
        }
    }
}

/// Compact profile for a sub-agent that has no Planner list of its own.
private struct AgentSummaryPopover: View {
    let agent: AgentProfile
    var manager: String? = nil
    @State private var showingChat = false

    private var managerName: String {
        if let manager { return manager }
        let leads = AgentRoster.load().values
            .filter { $0.subagentIDs.contains(agent.id) }.map(\.displayName).sorted()
        return leads.isEmpty ? "Not specified" : leads.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Avatar(initials: agent.initials, key: agent.id, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.displayName).font(.headline)
                    Text(agent.title).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            Label("Model: \(agent.modelName)", systemImage: "cpu").font(.caption)
            Text("Reports to: \(managerName)").font(.caption)
            Text("Agents: \(agent.subagentIDs.isEmpty ? "None" : agent.subagentIDs.joined(separator: ", "))")
                .font(.caption).foregroundStyle(.secondary)
            Text("Skills (\(agent.skills.count))").font(.caption.weight(.semibold))
            FlowLayout(spacing: 4) {
                ForEach(agent.skills, id: \.self) { SkillChip(skill: $0) }
            }
            AgentFacts(agent: agent)
            Text("Schedules / Crons: No configured jobs").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                MarkdownBlocks(text: agent.instructions)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
            Button("Open Definition File") { NSWorkspace.shared.open(agent.fileURL) }
            Button("Chat with \(agent.displayName)") { showingChat = true }
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .frame(width: 380)
        .sheet(isPresented: $showingChat) { AgentChatSheet(agent: agent) }
    }
}

// MARK: - Agent profile

/// Profile of one Digital Workforce agent: who it is, what it's told to do, which skills and
/// connectors it uses, when it runs, and the team under it.
struct AgentProfileView: View {
    let agent: AgentProfile
    let team: OrgNode
    let jobs: [ScheduledJob]
    var onOpenList: ((UUID) -> Void)?
    var onOpenChat: (() -> Void)? = nil

    @State private var instructionsExpanded = false
    @State private var selectedReport: OrgNode?
    @State private var showingChat = false

    private var reportingPath: [OrgNode] { team.path(to: agent.id) ?? [team] }
    private var directReports: [OrgNode] { reportingPath.last?.children ?? [] }
    private var managerName: String { reportingPath.dropLast().last?.name ?? "Not specified" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let mission = agent.mission {
                    card("Mission", symbol: "target") {
                        MarkdownBlocks(text: mission)
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    card("Skills (\(agent.skills.count))", symbol: "wand.and.stars") {
                        if agent.skills.isEmpty {
                            Text("No skills listed.").font(.callout).foregroundStyle(.secondary)
                        } else {
                            FlowLayout(spacing: 6) {
                                ForEach(agent.skills, id: \.self) { SkillChip(skill: $0) }
                            }
                        }
                    }
                    card("Tools & Connectors", symbol: "powerplug") {
                        AgentFacts(agent: agent)
                    }
                }
                    card("Schedules / Crons", symbol: "clock.arrow.circlepath") {
                        VStack(alignment: .leading, spacing: 6) {
                            if jobs.isEmpty {
                                Text("No configured scheduled jobs.").font(.callout).foregroundStyle(.secondary)
                            }
                            ForEach(jobs) { job in
                                HStack {
                                    Text(job.name).font(.callout.weight(.medium))
                                    Spacer()
                                    Text(job.schedule).font(.callout).foregroundStyle(.secondary)
                                    if let next = job.nextRun {
                                        Text("next \(next.formatted(.relative(presentation: .named)))")
                                            .font(.caption).foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                    }
                card("Organization", symbol: "person.3.sequence") {
                    organization
                }
                card("Instructions", symbol: "doc.text") {
                    DisclosureGroup(isExpanded: $instructionsExpanded) {
                        MarkdownBlocks(text: agent.instructions)
                            .textSelection(.enabled)
                            .padding(.top, 6)
                    } label: {
                        Text("System prompt from \(agent.fileURL.lastPathComponent)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .popover(item: $selectedReport) { node in
            if let profile = node.agent { AgentSummaryPopover(agent: profile, manager: agent.displayName) }
        }
        .sheet(isPresented: $showingChat) { AgentChatSheet(agent: agent) }
    }

    private var organization: some View {
        let path = team.path(to: agent.id) ?? [team]
        let direct = path.last?.children ?? []
        return VStack(alignment: .leading, spacing: 8) {
            Text("Reports to: \(managerName)").font(.callout.weight(.semibold))
            Text(path.map(\.name).joined(separator: " → ")).font(.callout.weight(.medium))
            if direct.isEmpty {
                Text("Agents reporting to \(agent.displayName): None")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !direct.isEmpty {
                Text(agent.id == "atlas" ? "Direct reports" : "Support agents")
                    .font(.caption).foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(direct) { node in
                        Button {
                            if let id = node.listID, let onOpenList { onOpenList(id) }
                            else { selectedReport = node }
                        } label: {
                            Label(node.name, systemImage: "person")
                                .font(.caption).padding(.horizontal, 8).padding(.vertical, 5)
                                .background(Theme.accent.opacity(0.08), in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Avatar(initials: agent.initials, key: agent.id, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(agent.displayName).font(.title.weight(.bold))
                Text(agent.title).font(.title3).foregroundStyle(.secondary)
                Text("Reports to: \(managerName)").font(.callout.weight(.medium)).foregroundStyle(Theme.accent)
                Text(directReports.isEmpty ? "Agents reporting to \(agent.displayName): None"
                     : "Agents reporting to \(agent.displayName): \(directReports.map(\.name).joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
                if !agent.summary.isEmpty {
                    Text(agent.summary).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Label("Model: \(agent.modelName)", systemImage: "cpu").font(.caption).foregroundStyle(.secondary)
                Button {
                    if let onOpenChat { onOpenChat() } else { showingChat = true }
                } label: {
                    Label("Chat with \(agent.displayName)", systemImage: "bubble.left.and.bubble.right")
                }
                .buttonStyle(.borderedProminent)
                Button("Edit Instructions…") { NSWorkspace.shared.open(agent.fileURL) }
                    .help("Open \(agent.fileURL.path) in your editor")
            }
        }
    }

    private func card<Content: View>(_ title: String, symbol: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// Built-in tools and detected connectors.
private struct AgentFacts: View {
    let agent: AgentProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Tools").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(agent.tools.isEmpty ? "All tools (inherits the session's tools and MCP connectors)"
                                         : agent.tools.joined(separator: ", "))
                    .font(.caption)
            }
            Text("Connectors").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if agent.connectors.isEmpty {
                Text("None listed.").font(.caption).foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(agent.connectors) { connector in
                        Label(connector.name, systemImage: connector.symbol)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                }
            }
        }
    }
}

private struct SkillChip: View {
    let skill: String

    var body: some View {
        let parts = skill.split(separator: ":", maxSplits: 1)
        HStack(spacing: 0) {
            if parts.count == 2 {
                Text(parts[0] + ":").foregroundStyle(.tertiary)
                Text(parts[1])
            } else {
                Text(skill)
            }
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
    }
}

// MARK: - Workforce overview

/// Compact reporting hierarchy with each staff member's operational facts on one card.
struct WorkforceOverviewView: View {
    let groupName: String
    let chart: OrgNode
    let agents: [(profile: AgentProfile, listID: UUID?)]
    let jobs: [ScheduledJob]
    var onOpenList: ((UUID) -> Void)?
    @State private var detailAgent: AgentProfile?

    private var operationalStaff: [OrgNode] {
        chart.children.first { $0.id == "atlas" }?.children ?? []
    }

    var body: some View {
        ScrollView { overview }
        .sheet(item: $detailAgent) { agent in
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Done") { detailAgent = nil }.keyboardShortcut(.cancelAction)
                }.padding(12)
                AgentProfileView(agent: agent, team: detailTeam(for: agent),
                                 jobs: jobs.filter { $0.detail?.lowercased() == agent.id }, onOpenList: onOpenList)
            }
            .frame(minWidth: 700, minHeight: 600)
        }
    }

    var overview: some View {
        VStack(spacing: 5) {
            HStack {
                Text(groupName).font(.title2.weight(.bold))
                Spacer()
                Text("\(agents.count) staff · \(chart.descendantIDs.subtracting(agents.map(\.profile.id)).count) helpers")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Avatar(initials: chart.initials, key: chart.id, size: 24)
                Text(chart.name).font(.callout.weight(.semibold))
                Text(chart.title).font(.caption).foregroundStyle(.secondary)
            }
            Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 1, height: 8)
            Text("Reports directly to \(chart.name)").font(.caption2).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
                ForEach(chart.children) { node in
                    staffCard(node).frame(maxWidth: 320)
                }
            }
            if !operationalStaff.isEmpty {
                Text("Reports to Atlas").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.top, 2)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 10, alignment: .top)],
                          alignment: .leading, spacing: 10) {
                    ForEach(operationalStaff) { node in staffCard(node) }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: 1150)
        .frame(maxWidth: .infinity)
    }

    private func detailTeam(for agent: AgentProfile) -> OrgNode {
        var node = OrgChartBuilder.node(for: agent, list: nil, roster: AgentRoster.load(), focus: agent.id)
        if !AgentRoster.principalReportIDs.contains(agent.id),
           var atlas = chart.children.first(where: { $0.id == "atlas" }) {
            atlas.children = [node]
            node = atlas
        }
        var root = chart
        root.children = [node]
        return root
    }

    private func staffCard(_ node: OrgNode) -> some View {
        Button {
            if let id = node.listID, let onOpenList { onOpenList(id) }
            else { detailAgent = node.agent }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 7) {
                    Avatar(initials: node.initials, key: node.id, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(node.name).font(.callout.weight(.semibold)).lineLimit(1)
                        Text(node.title).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }.frame(height: 28, alignment: .top)
                if let agent = node.agent {
                    fact("Model", agent.modelName)
                    fact("Reports to", AgentRoster.principalReportIDs.contains(agent.id) ? chart.name : "Atlas")
                    fact("Agents", node.children.isEmpty ? "None" : node.children.map(\.name).joined(separator: ", "))
                    fact("Skills", agent.skills.isEmpty ? "None listed" : "\(agent.skills.count) · " + agent.skills.joined(separator: ", "))
                    fact("Tools", agent.tools.isEmpty ? "Inherited session tools" : agent.tools.joined(separator: ", "))
                    fact("Connectors", agent.connectors.isEmpty ? "None listed" : agent.connectors.map(\.name).joined(separator: ", "))
                    let scheduled = jobs.filter { $0.detail?.lowercased() == agent.id }
                    fact("Schedules", scheduled.isEmpty ? "No scheduled jobs" : scheduled.map(\.schedule).joined(separator: "; "))
                        .help(scheduled.map { "\($0.name): \($0.schedule)" }.joined(separator: "; "))
                }
            }
            .padding(7)
            .frame(maxWidth: .infinity, minHeight: 125, alignment: .topLeading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(node.name)'s full profile")
    }

    private func fact(_ label: String, _ value: String, lines: Int = 1) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(label).foregroundStyle(.secondary).frame(width: 59, alignment: .leading)
            Text(value).foregroundStyle(.primary).lineLimit(lines)
                .frame(maxWidth: .infinity, alignment: .leading).help(value)
        }
        .font(.system(size: 9))
    }
}

// MARK: - Helpers

/// Wrapping row layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

/// Minimal block-level markdown: headings, bullets, numbered items, code fences, paragraphs
/// (inline styling via AttributedString).
struct MarkdownBlocks: View {
    let text: String

    private enum Block: Hashable {
        case heading(String), bullet(String, indent: Int), numbered(String, String), code(String), paragraph(String)
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        func flush() {
            if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
        }
        for raw in text.components(separatedBy: "\n") {
            if raw.hasPrefix("```") {
                if let lines = code { result.append(.code(lines.joined(separator: "\n"))); code = nil }
                else { flush(); code = [] }
                continue
            }
            if code != nil { code?.append(raw); continue }
            let line = raw.trimmingCharacters(in: .whitespaces)
            let indent = (raw.count - raw.drop(while: { $0 == " " }).count) / 2
            if line.isEmpty { flush() }
            else if line.hasPrefix("#") {
                flush(); result.append(.heading(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush(); result.append(.bullet(String(line.dropFirst(2)), indent: indent))
            } else if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
                      line[line.index(after: dot)...].hasPrefix(" ") {
                flush(); result.append(.numbered(String(line[...dot]), String(line[line.index(dot, offsetBy: 2)...])))
            } else if case .bullet(let prev, let i)? = result.last, paragraph.isEmpty, indent > 0 {
                result[result.count - 1] = .bullet(prev + " " + line, indent: i)   // wrapped bullet
            } else if case .numbered(let n, let prev)? = result.last, paragraph.isEmpty, indent > 0 {
                result[result.count - 1] = .numbered(n, prev + " " + line)
            } else {
                paragraph.append(line)
            }
        }
        if let lines = code { result.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let s):
                    Text(inline(s)).font(.callout.weight(.semibold)).padding(.top, 6)
                case .bullet(let s, let indent):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        Text(inline(s))
                    }
                    .padding(.leading, CGFloat(indent) * 14)
                case .numbered(let n, let s):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(n).foregroundStyle(.secondary).monospacedDigit()
                        Text(inline(s))
                    }
                case .code(let s):
                    Text(s)
                        .font(.system(.caption, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                case .paragraph(let s):
                    Text(inline(s))
                }
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}
