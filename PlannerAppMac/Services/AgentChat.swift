import Foundation
import Darwin

struct AgentChatMessage: Codable, Identifiable, Equatable {
    let id: String
    let role: String
    let text: String
    let createdAt: String
    var status: String?
    var error: String?
    var model: String?
}

@MainActor
final class AgentChat: ObservableObject {
    private struct Conversation: Decodable {
        var messages: [AgentChatMessage]
        var activePID: Int32?
    }
    private static var conversations: [String: AgentChat] = [:]
    static func conversation(for agentID: String) -> AgentChat {
        if let saved = conversations[agentID] { return saved }
        let chat = AgentChat(agentID: agentID)
        conversations[agentID] = chat
        return chat
    }

    @Published private(set) var messages: [AgentChatMessage] = []
    @Published private(set) var isReplying = false
    @Published private(set) var error: String?
    private let agentID: String
    private let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("DigitalWorkforce")
    private var process: Process?
    var canStop: Bool { process?.isRunning == true }
    private var timer: Timer?
    private var canSend: Bool { !isReplying && process?.isRunning != true }
    private var historyURL: URL { root.appendingPathComponent("chats/\(agentID).json") }

    private init(agentID: String) {
        self.agentID = agentID
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, !text.isEmpty else { return }
        let message = AgentChatMessage(id: UUID().uuidString.lowercased(), role: "user", text: text,
                                       createdAt: ISO8601DateFormatter().string(from: Date()), status: "pending")
        messages.append(message)
        run(message)
    }

    func retry(_ message: AgentChatMessage) {
        guard canSend else { return }
        run(message)
    }

    func stop() { process?.terminate() }

    private func run(_ message: AgentChatMessage) {
        error = nil
        isReplying = true
        let requests = root.appendingPathComponent("chats/requests", isDirectory: true)
        let requestURL = requests.appendingPathComponent(message.id + ".json")
        do {
            try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(message).write(to: requestURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: requestURL.path)
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            task.arguments = [root.appendingPathComponent("bin/chat-agent.py").path, agentID, requestURL.path]
            // The worker saves the reply; it must not depend on an open view or stdout pipe.
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            task.terminationHandler = { [weak self] task in
                Task { @MainActor in
                    guard let self else { return }
                    self.process = nil
                    self.reload()
                    if task.terminationStatus != 0 && self.messages.last?.status != "failed" {
                        self.error = "The agent couldn't reply. Try again."
                        if let index = self.messages.lastIndex(where: { $0.id == message.id }) {
                            self.messages[index].status = "failed"
                            self.messages[index].error = self.error
                        }
                    }
                }
            }
            process = task
            try task.run()
        } catch {
            process = nil
            isReplying = false
            self.error = "Couldn't start this conversation: \(error.localizedDescription)"
            if let index = messages.firstIndex(where: { $0.id == message.id }) {
                messages[index].status = "failed"
                messages[index].error = self.error
            }
        }
    }

    private func reload() {
        guard let data = try? Data(contentsOf: historyURL),
              let saved = try? JSONDecoder().decode(Conversation.self, from: data) else {
            isReplying = process?.isRunning == true
            return
        }
        // Keep a just-sent message while the worker is waiting to acquire its lock.
        if process?.isRunning == true, let pending = messages.last,
           pending.role == "user", !saved.messages.contains(where: { $0.id.lowercased() == pending.id.lowercased() }) {
            let next = saved.messages + [pending]
            if messages != next { messages = next }
        } else {
            if messages != saved.messages { messages = saved.messages }
        }
        let workerAlive = saved.activePID.map { kill($0, 0) == 0 } ?? false
        let replying = process?.isRunning == true || workerAlive
        if isReplying != replying { isReplying = replying }
        if !isReplying, let index = messages.lastIndex(where: { $0.status == "pending" }) {
            messages[index].status = "failed"
            messages[index].error = "The conversation was interrupted. Retry to continue."
        }
    }
}
