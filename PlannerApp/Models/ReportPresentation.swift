import Foundation

/// Presentation shared by existing synced reports and newly published briefs.
enum ReportPresentation {
    static func title(_ text: String) -> String {
        text.replacingOccurrences(of: "Morning Updates", with: "Morning Brief", options: .caseInsensitive)
    }

    static func isMorningBrief(file: String, title: String) -> Bool {
        let name = file.lowercased()
        let heading = self.title(title).lowercased()
        return heading.contains("morning brief") || heading.contains("daily brief") || name.contains("-oracle-updates")
            || name.contains("morning-brief")
    }

    /// The consolidated Morning Brief stays first within its own day.
    static func isPinnedMorningBrief(file: String, title: String) -> Bool {
        let name = file.lowercased()
        return self.title(title).localizedCaseInsensitiveContains("morning brief")
            || name.contains("-oracle-updates") || name.contains("morning-brief")
    }

    /// Planner ▸ Updates holds only the briefs and weekly updates Alfred reads; everything else the agents
    /// publish (project checks, scans, watchers, monitors, guides, boards) is a log (Mac: Planner ▸ Logs).
    /// File names are `<date>-<agent>[-<kind>].html` (see ~/DigitalWorkforce/prompts/_report-scopes.md).
    static func isUpdate(file: String, title: String) -> Bool {
        if isPinnedMorningBrief(file: file, title: title) { return true }
        let name = file.lowercased()
        let stem = (name as NSString).lastPathComponent
            .replacingOccurrences(of: #"^\d{4}-\d{2}-\d{2}-"#, with: "", options: .regularExpression)
        if ["atlas.html", "oracle.html", "oracle-business.html", "nova-ai-news.html",
            "helm-weekly.html", "vesta-weekly-hr.html"].contains(stem) { return true }
        let heading = self.title(title).lowercased()
        return ["business brief", "weekly business strategy", "weekly ai news", "weekly project update",
                "weekly hr brief"].contains { heading.contains($0) }
    }

    static func dayKey(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
