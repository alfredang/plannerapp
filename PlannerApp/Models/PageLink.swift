import Foundation

/// A page an item points at, e.g. a client's overview report: an agent report in the
/// Planner workspace (`reports/<file>.html`), an absolute file path, or a web address.
/// It lives on a "Page: …" line in the item's notes, so it syncs through the existing
/// `notes` field with no CloudKit schema change.
enum PageLink {
    static let tag = "Page:"

    /// A tagged line; the rest of the line is the link (file paths may contain spaces).
    private static let linkRegex = try? NSRegularExpression(pattern: #"(?im)^[ \t]*Page:[ \t]*(\S[^\n]*?)[ \t]*$"#)
    /// Compiled once: both run for every row each time a list renders.
    private static let reportMentionRegex = try? NSRegularExpression(
        pattern: #"(?i)(?<![\w/.-])(reports/[^\s"'<>()]+?\.html?)(?![\w/-])"#)
    private static let linePattern = #"(?im)^[ \t]*Page:[^\n]*\n?"#

    /// The page link in `notes`, if any.
    static func find(in notes: String) -> String? {
        guard let regex = linkRegex,
              let match = regex.firstMatch(in: notes, range: NSRange(notes.startIndex..., in: notes)),
              let range = Range(match.range(at: 1), in: notes) else { return nil }
        return String(notes[range])
    }

    /// `notes` without its "Page:" line (for previews).
    static func withoutLink(_ notes: String) -> String {
        notes.replacingOccurrences(of: linePattern, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `notes` with the page link set to `link` (normalised), or removed when it's empty.
    static func notes(_ notes: String, setting link: String) -> String {
        let base = withoutLink(notes)
        let new = normalized(link)
        guard !new.isEmpty else { return base }
        return base.isEmpty ? "\(tag) \(new)" : base + "\n\(tag) \(new)"
    }

    /// What gets stored: a bare report name ("x.html") becomes "reports/x.html"; web
    /// addresses, absolute paths and other workspace-relative paths are kept as given.
    static func normalized(_ raw: String) -> String {
        let link = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty, !isWeb(link), !link.hasPrefix("/"), !link.hasPrefix("~"),
              !link.contains("/") else { return link }
        return "reports/" + link
    }

    /// Where the page is: a web URL, an absolute file, or a file under `workspace` (the
    /// Planner agent workspace on the Mac). Relative links need a workspace.
    static func url(for link: String, workspace: URL?) -> URL? {
        if isWeb(link) { return URL(string: link) }
        if link.hasPrefix("/") || link.hasPrefix("~") {
            return URL(fileURLWithPath: (link as NSString).expandingTildeInPath)
        }
        guard let workspace, !link.contains("..") else { return nil }
        return workspace.appendingPathComponent(link)
    }

    /// A report mentioned anywhere in the notes ("… reports/2026-10-30-acme.html"), for items
    /// written before page links existed.
    static func reportMention(in notes: String) -> String? {
        guard let regex = reportMentionRegex,
              let match = regex.firstMatch(in: notes, range: NSRange(notes.startIndex..., in: notes)),
              let range = Range(match.range(at: 1), in: notes) else { return nil }
        return String(notes[range])
    }

    static func isWeb(_ link: String) -> Bool {
        let lower = link.lowercased()
        return lower.hasPrefix("https://") || lower.hasPrefix("http://")
    }
}

extension PlannerItem {
    /// The page this item points at ("Page: …" line in its notes), if any.
    var pageLink: String? { PageLink.find(in: notes) }

    /// What a click opens: the page link, else a report the notes mention.
    var pageTarget: String? { pageLink ?? PageLink.reportMention(in: notes) }
}

extension PlannerKind {
    /// Files content that agents wrote as to-dos as pages instead. A "Client Overview" was
    /// filed as a Critical to-do per client, so 75 of them crowded out the real work in
    /// To-Do and Pinned. Idempotent: safe to run on every launch, and it also catches an
    /// agent that files one the old way. Archived copies are left alone (restoring them
    /// could bring back real duplicates). A page or idea checked off on an older iPhone build
    /// (which reads an unknown kind as a to-do) is restored too — they are never done. Returns
    /// how many items changed.
    @discardableResult
    static func migrateContentToPages(in items: [PlannerItem]) -> Int {
        var converted = 0
        for item in items {
            let misfiled = item.kind == .task && !item.isArchived
                && item.pageTarget != nil && isContentTitle(item.title)
            let checkedOffContent = (item.isPage || item.isIdea) && item.isDone
            guard misfiled || checkedOffContent else { continue }
            item.makeContent(item.isIdea ? .idea : .page)
            converted += 1
        }
        return converted
    }

    /// Titles that name a document rather than a piece of work.
    static func isContentTitle(_ title: String) -> Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasSuffix("overview")
    }
}
