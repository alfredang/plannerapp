import Foundation

/// One Claude Code agent from `~/.claude/agents/<name>.md` — the Digital Workforce staff
/// (Atlas, Forge, …) and the helper agents they delegate to (courseware-qa, …).
struct AgentProfile: Identifiable, Hashable {
    struct Section: Hashable {
        var heading: String
        var body: String
    }

    var id: String              // frontmatter `name`, e.g. "atlas"
    var displayName: String     // "Atlas"
    var title: String           // "Chief of Staff to Dr Alfred Ang"
    var summary: String         // rest of the description
    var model: String?
    /// Frontmatter `tools`; empty means the agent inherits every tool.
    var tools: [String]
    var instructions: String    // the markdown body (system prompt)
    var sections: [Section]
    var skills: [String]
    var connectors: [AgentRoster.Connector]
    /// Other agents this one names in its instructions — its sub-agents.
    var subagentIDs: [String]
    var fileURL: URL

    var mission: String? {
        sections.first { $0.heading.lowercased().hasPrefix("mission") }?.body
    }

    var modelName: String {
        switch model {
        case "claude-opus-5-5": return "Opus 5.5"
        case "claude-sonnet-5-5": return "Sonnet 5.5"
        case "claude-haiku-5-5": return "Haiku 5.5"
        default: return model ?? "Inherited"
        }
    }

    var initials: String {
        let words = displayName.split(separator: " ")
        return words.count > 1
            ? words.prefix(2).compactMap(\.first).map(String.init).joined()
            : String(displayName.prefix(1))
    }
}

/// Reads the agent definitions behind the Digital Workforce. A Planner list whose name matches
/// an agent (`Atlas` ↔ `atlas.md`) shows that agent's profile; a list of such lists shows the
/// org chart. Read-only — the `.md` files stay the single source of truth.
enum AgentRoster {
    static let staffIDs = ["atlas", "mercury", "muse", "sage", "sentinel", "forge", "ledger", "oracle", "nova"]
    private static let home = FileManager.default.homeDirectoryForCurrentUser
    static var agentsDir: URL { home.appendingPathComponent(".claude/agents", isDirectory: true) }
    static var companyURL: URL { home.appendingPathComponent("DigitalWorkforce/COMPANY.md") }

    /// Reporting lines come from the same company profile the staff read.
    static var principalReportIDs: Set<String> {
        guard let company = try? String(contentsOf: companyURL, encoding: .utf8) else {
            return ["atlas", "oracle", "nova"]
        }
        let lines = company.lowercased().components(separatedBy: .newlines)
        let ids = staffIDs.filter { id in
            lines.contains { $0.hasPrefix("- \(id) ") && $0.contains("reports directly to") }
        }
        return ids.isEmpty ? ["atlas", "oracle", "nova"] : Set(ids)
    }

    /// Every agent, keyed by lowercased name.
    static func load() -> [String: AgentProfile] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: agentsDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }
        var parsed = files.compactMap { url -> AgentProfile? in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return parse(text, url: url)
        }
        // Sub-agents need the full roster: any other agent named in `backticks` in the body.
        let ids = Set(parsed.map(\.id))
        for i in parsed.indices {
            let mentioned = codeSpans(in: parsed[i].instructions).map { $0.lowercased() }
            var seen = Set<String>()
            parsed[i].subagentIDs = mentioned.filter { $0 != parsed[i].id && ids.contains($0) && seen.insert($0).inserted }
            parsed[i].skills.removeAll { ids.contains($0.lowercased()) }
        }
        return Dictionary(parsed.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// The person at the top of the chart, from COMPANY.md's `**Principal:** Name — title.` line.
    static func principal(fallback: String) -> (name: String, title: String) {
        guard let text = try? String(contentsOf: companyURL, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.contains("**Principal:**") }) else {
            return (fallback, "Principal")
        }
        let rest = line.components(separatedBy: "**Principal:**").last?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let parts = rest.components(separatedBy: " — ")
        let name = parts.first?.trimmingCharacters(in: .whitespaces) ?? fallback
        var title = parts.count > 1 ? firstSentence(parts[1]) : "Principal"
        title = title.prefix(1).uppercased() + title.dropFirst()
        return (name.isEmpty ? fallback : name, title)
    }

    // MARK: - Parsing

    static func parse(_ text: String, url: URL) -> AgentProfile? {
        var front: [String: String] = [:]
        var body = text
        if text.hasPrefix("---"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) {
            for line in text[text.index(text.startIndex, offsetBy: 3)..<end.lowerBound].split(separator: "\n") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                    value = String(value.dropFirst().dropLast())
                }
                front[key] = value
            }
            body = String(text[end.upperBound...])
            if let nl = body.firstIndex(of: "\n") { body = String(body[body.index(after: nl)...]) }
        }
        let id = (front["name"] ?? url.deletingPathExtension().lastPathComponent).lowercased()
        guard !id.isEmpty else { return nil }

        // "Atlas — Chief of Staff to Dr Alfred Ang. Owns the schedule: …"
        // Escaped newlines (example blocks in some descriptions) end the useful part.
        let description = (front["description"] ?? "").components(separatedBy: "\\n").first ?? ""
        var displayName = prettyName(id)
        var tagline = description
        if let dash = description.range(of: " — "), description[..<dash.lowerBound].split(separator: " ").count <= 3 {
            displayName = String(description[..<dash.lowerBound])
            tagline = String(description[dash.upperBound...])
        }
        let sentence = firstSentence(tagline)
        let summary = tagline.dropFirst(sentence.count).trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        let title = shortTitle(sentence)

        let sections = splitSections(body)
        let toolsSection = sections.first { $0.heading.lowercased().contains("skills") || $0.heading.lowercased().contains("tools") }?.body ?? ""
        let skills = codeSpans(in: toolsSection).filter { span in
            !span.contains(where: { $0 == "/" || $0 == "~" || $0 == " " || $0 == "." })
        }

        let tools = (front["tools"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "*" }

        return AgentProfile(
            id: id, displayName: displayName, title: title, summary: summary,
            model: front["model"], tools: tools,
            instructions: body.trimmingCharacters(in: .whitespacesAndNewlines),
            sections: sections, skills: uniqued(skills),
            connectors: connectors(in: description + "\n" + body + "\n" + tools.joined(separator: " ")),
            subagentIDs: [], fileURL: url)
    }

    private static func splitSections(_ body: String) -> [AgentProfile.Section] {
        var result: [AgentProfile.Section] = []
        var heading: String?
        var lines: [Substring] = []
        func flush() {
            if let heading { result.append(.init(heading: heading, body: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))) }
        }
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                flush()
                heading = String(line.dropFirst(3))
                lines = []
            } else {
                lines.append(line)
            }
        }
        flush()
        return result
    }

    /// `inline code` spans, in order.
    private static func codeSpans(in text: String) -> [String] {
        let parts = text.components(separatedBy: "`")
        guard parts.count > 2 else { return [] }
        return stride(from: 1, to: parts.count - 1, by: 2).map { parts[$0] }.filter { !$0.isEmpty && !$0.contains("\n") }
    }

    private static func firstSentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let dot = trimmed.range(of: ". ") { return String(trimmed[..<dot.lowerBound]) }
        return trimmed.hasSuffix(".") ? String(trimmed.dropLast()) : trimmed
    }

    /// "Quality reviewer for WSQ courseware — audits …" → "Quality reviewer for WSQ courseware";
    /// "Use this agent when the user wants to improve code …" → "Improve code …".
    private static func shortTitle(_ sentence: String) -> String {
        var title = sentence.components(separatedBy: " — ").first ?? sentence
        for lead in ["Use this agent when the user wants to ", "Use this agent when you want ",
                     "Use this agent when you want to ", "Use this agent to ", "Use this agent when "] {
            if title.hasPrefix(lead) {
                title = String(title.dropFirst(lead.count))
                title = title.prefix(1).uppercased() + title.dropFirst()
                break
            }
        }
        return title
    }

    private static func prettyName(_ id: String) -> String {
        let acronyms: Set<String> = ["qa", "ui", "ux", "wsq", "ibf", "lms", "tms", "ai"]
        return id.split(separator: "-").map { word in
            acronyms.contains(String(word)) ? word.uppercased() : word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }

    private static func uniqued(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }

    // MARK: - Connectors

    /// An external system or built-in tool an agent's instructions say it uses.
    struct Connector: Hashable, Identifiable {
        var name: String
        var symbol: String
        var id: String { name }
    }

    /// Recognised connectors and the phrases that reveal them (matched case-insensitively).
    private static let knownConnectors: [(Connector, [String])] = [
        (.init(name: "Planner", symbol: "checklist"), ["planner bridge", "planner-state", "planner commands"]),
        (.init(name: "Google Calendar", symbol: "calendar"), ["google calendar"]),
        (.init(name: "Gmail", symbol: "envelope"), ["gmail"]),
        (.init(name: "Google Drive", symbol: "externaldrive"), ["google drive", "gdrive"]),
        (.init(name: "Microsoft 365", symbol: "building.2"), ["microsoft 365", "outlook"]),
        (.init(name: "Web Search", symbol: "magnifyingglass"), ["websearch", "web search"]),
        (.init(name: "Web Fetch", symbol: "globe"), ["webfetch"]),
        (.init(name: "Canva", symbol: "paintpalette"), ["canva"]),
        (.init(name: "LinkedIn", symbol: "person.2"), ["linkedin"]),
        (.init(name: "GitHub", symbol: "chevron.left.forwardslash.chevron.right"), ["github"]),
        (.init(name: "Xero", symbol: "dollarsign.circle"), ["xero"]),
        (.init(name: "QuickBooks", symbol: "dollarsign.circle"), ["quickbooks"]),
        (.init(name: "LMS / TMS", symbol: "graduationcap"), ["lms-push", "tms-push", "lms-tms"]),
        (.init(name: "Schedule guardian", symbol: "shield.lefthalf.filled"), ["guardian.py"]),
        (.init(name: "Shell", symbol: "terminal"), ["bash"]),
    ]

    private static func connectors(in text: String) -> [Connector] {
        let lower = text.lowercased()
        return knownConnectors.filter { _, phrases in phrases.contains { lower.contains($0) } }.map(\.0)
    }
}
