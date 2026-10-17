import SwiftUI

struct MacAgentChatView: View {
    let agent: AgentProfile
    @ObservedObject private var chat: AgentChat
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    init(agent: AgentProfile) {
        self.agent = agent
        _chat = ObservedObject(wrappedValue: AgentChat.conversation(for: agent.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right.fill").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Chat with \(agent.displayName)").font(.headline)
                    Text(agent.title).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(agent.modelName).font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if chat.messages.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Discuss your plans with \(agent.displayName).")
                                    .font(.title3.weight(.semibold))
                                Text("This conversation is saved separately from your chats with other agents.")
                                    .foregroundStyle(.secondary)
                                if agent.id == "oracle" {
                                    Button("Explore business opportunities with Adecco") {
                                        chat.send("What business opportunities could we explore with Adecco? Compare realistic options and recommend the best next move and what I should say.")
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .padding(.vertical, 24)
                        }
                        ForEach(chat.messages) { message in
                            messageView(message).id(message.id)
                        }
                        if chat.isReplying {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("\(agent.displayName) is replying…").foregroundStyle(.secondary)
                                if chat.canStop { Button("Stop") { chat.stop() }.buttonStyle(.borderless) }
                            }
                            .id("replying")
                        }
                        if let error = chat.error {
                            Text(error).font(.callout).foregroundStyle(.red)
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: chat.messages.count) {
                    withAnimation {
                        scroll.scrollTo(chat.messages.last?.id,
                                        anchor: chat.messages.last?.role == "assistant" ? .top : .bottom)
                    }
                }
                .onAppear { scroll.scrollTo(chat.messages.last?.id, anchor: .bottom) }
            }
            Divider()
            HStack(alignment: .bottom, spacing: 10) {
                TextEditor(text: $draft)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(height: 56)
                    .overlay(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text("Message \(agent.displayName)…")
                                .foregroundStyle(.tertiary).padding(.top, 3).padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    .focused($composerFocused)
                    .accessibilityLabel("Message \(agent.displayName)")
                    .accessibilityIdentifier("agentChat.composer")
                Button { send() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .disabled(chat.isReplying || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send to \(agent.displayName)")
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel("Send to \(agent.displayName)")
            }
            .padding(16)
        }
        .background(Theme.bg)
        .onAppear { composerFocused = true }
    }

    private func send() {
        guard !chat.isReplying, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        chat.send(draft)
        draft = ""
    }

    private func messageView(_ message: AgentChatMessage) -> some View {
        let isUser = message.role == "user"
        return HStack {
            if isUser { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 6) {
                Text(isUser ? "You" : agent.displayName).font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                if isUser {
                    Text(message.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ChatMarkdown(text: message.text).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if message.status == "failed" {
                    Text(message.error ?? "Couldn't reply just now.").font(.caption).foregroundStyle(.red)
                    Button("Retry") { chat.retry(message) }.disabled(chat.isReplying)
                }
            }
            .padding(14)
            .background(isUser ? Theme.accent.opacity(0.10) : Theme.card, in: RoundedRectangle(cornerRadius: 12))
            if !isUser { Spacer(minLength: 40) }
        }
    }
}

/// Use the profile's markdown renderer, with readable option tables for discussions.
private struct ChatMarkdown: View {
    let text: String
    private enum Block { case text(String), table([[String]]) }
    private var blocks: [Block] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [Block] = [], paragraph: [String] = []
        var index = 0
        func cells(_ line: String) -> [String] {
            var parts = line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.first == "" { parts.removeFirst() }
            if parts.last == "" { parts.removeLast() }
            return parts
        }
        while index < lines.count {
            let separators = index + 1 < lines.count ? cells(lines[index + 1]) : []
            if lines[index].contains("|"), separators.count > 1,
               separators.allSatisfy({ $0.range(of: "^:?-{3,}:?$", options: .regularExpression) != nil }) {
                if !paragraph.isEmpty { blocks.append(.text(paragraph.joined(separator: "\n"))); paragraph = [] }
                var rows = [cells(lines[index])]
                index += 2
                while index < lines.count && lines[index].contains("|") {
                    rows.append(cells(lines[index])); index += 1
                }
                blocks.append(.table(rows))
            } else {
                paragraph.append(lines[index]); index += 1
            }
        }
        if !paragraph.isEmpty { blocks.append(.text(paragraph.joined(separator: "\n"))) }
        return blocks
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let text): MarkdownBlocks(text: text)
                case .table(let rows):
                    ScrollView(.horizontal) {
                        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 10) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                                GridRow {
                                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                        Text((try? AttributedString(markdown: cell)) ?? AttributedString(cell))
                                            .font(.callout).fontWeight(index == 0 ? .semibold : .regular)
                                            .frame(minWidth: 120, maxWidth: 200, alignment: .topLeading)
                                    }
                                }
                                if index == 0 { Divider().gridCellColumns(rows[0].count) }
                            }
                        }
                    }
                }
            }
        }
    }
}

struct AgentChatSheet: View {
    let agent: AgentProfile
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack { Spacer(); Button("Done") { dismiss() } }.padding(10)
            MacAgentChatView(agent: agent)
        }
        .frame(minWidth: 560, minHeight: 540)
    }
}
