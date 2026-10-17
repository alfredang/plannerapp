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

    static func dayKey(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
