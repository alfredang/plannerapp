import Foundation

/// A training class. Classes, their calendar events and their Google Meet links are set up
/// only by AI-LMS-TMS, AI-MMS or the Google Apps Script. Planner shows them and follows
/// changes made in the calendar, but never creates, edits or copies a class event (see
/// `CalendarSync.write`). Keep the rule in step with `is_class` in Hermes
/// `calendar-sync/dual_sync.py`.
enum ClassEvent {
    /// TMS delivery-mode tag in a class title: "[VIRTUAL] WSQ - …", "*Day 2 - [HYBRID] …".
    private static let modeTag =
        #"(?i)\[(VIRTUAL|HYBRID|EXTERNAL|PHYSICAL|CLASSROOM|ONSITE|ON-SITE|F2F|FACE[- ]TO[- ]FACE|IN[- ]PERSON|BLENDED|ONLINE)\]"#
    /// "WSQ - " in a title.
    private static let wsqTitle = #"(?i)(^|[\s*\-–—\]])WSQ\s*[-–—]\s"#
    /// Course facts the TMS, MMS and the Apps Script write into a class event's description.
    private static let classNotes = #"(?im)\bTGS-\d{10}\b|\bCourse Run ID\b|^\s*Class:\s"#
    /// The TMS sends class invites from this account.
    static let organisers: Set<String> = ["sales@tertiarycourses.com.sg"]

    static func isClass(title: String, notes: String = "", organiser: String? = nil) -> Bool {
        if let organiser, organisers.contains(organiser.lowercased()) { return true }
        return matches(modeTag, title) || matches(wsqTitle, title) || matches(classNotes, notes)
    }

    static func isClass(_ item: PlannerItem) -> Bool {
        isClass(title: item.title, notes: item.notes)
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}
