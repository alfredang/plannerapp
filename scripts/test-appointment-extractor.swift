// Regression tests for the appointment chat's extractor (paste an invite / say it → draft).
// Run: xcrun swiftc -parse-as-library PlannerApp/Models/*.swift PlannerApp/Services/*.swift scripts/test-appointment-extractor.swift -o /tmp/planner-appointment-tests && /tmp/planner-appointment-tests
// Dates are checked on either path: with Apple Intelligence available the model picks the
// phrases, without it the deterministic parser does — the resulting dates must agree.
import Foundation

@main
struct AppointmentExtractorTests {
    static var failures = 0
    static let cal = Calendar.current

    static func check(_ condition: Bool, _ message: String) {
        print(condition ? "PASS  \(message)" : "FAIL  \(message)")
        if !condition { failures += 1 }
    }

    static func hm(_ date: Date?) -> String {
        guard let date else { return "nil" }
        let c = cal.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? -1, c.minute ?? -1)
    }

    static func show(_ d: AppointmentDraft) {
        print("      title=\(d.title) | date=\(d.date.map { "\($0.formatted())" } ?? "nil") time=\(d.hasTime)"
              + " end=\(hm(d.end)) | loc=\(d.location) | link=\(d.meetingLink) | AI=\(d.usedAppleIntelligence)")
        if !d.details.isEmpty { print("      details=\(d.details.replacingOccurrences(of: "\n", with: " / "))") }
    }

    static func main() async {
        let anchor = cal.date(from: DateComponents(year: 2026, month: 11, day: 12))!

        // 1. A spoken one-liner.
        var d = await AppointmentExtractor.extract(from: "Lunch with Sam on 6 Nov 2026 at 1pm")
        show(d)
        check(d.title.lowercased().contains("lunch"), "one-liner: title keeps the words")
        check(d.hasTime && hm(d.date) == "13:00", "one-liner: 1pm")
        check(d.date.map { cal.component(.day, from: $0) } == 6, "one-liner: on the 6th")

        // 2. A pasted invite: date and time on separate lines, end time, location, Meet link.
        let invite = """
            Invitation: AI Training Kickoff with UOB
            Date: Tuesday, 17 November 2026
            Time: 10:00 AM – 11:30 AM (Singapore Standard Time)
            Location: Level 12, UOB Plaza 1
            Join with Google Meet: meet.google.com/abc-defg-hij
            Organizer: Mei Ling Tan
            """
        d = await AppointmentExtractor.extract(from: invite)
        show(d)
        check(!d.title.isEmpty, "invite: has a title")
        check(d.date.map { cal.component(.day, from: $0) } == 17, "invite: on the 17th")
        check(d.hasTime && hm(d.date) == "10:00", "invite: starts 10:00")
        check(d.meetingLink == "meet.google.com/abc-defg-hij", "invite: Meet link found")
        check(d.notes.contains("Meeting link: meet.google.com/abc-defg-hij"), "invite: link stored in notes")
        if d.usedAppleIntelligence {
            check(hm(d.end) == "11:30", "invite: ends 11:30 (model path)")
            check(d.notes.contains("Ends at 11:30"), "invite: end time stored in notes")
        }

        // 3. A bare time lands on the anchor day (the day picked in the calendar).
        d = await AppointmentExtractor.extract(from: "Call with Ryan at 4pm", anchorDay: anchor)
        show(d)
        check(d.date.map { cal.isDate($0, inSameDayAs: anchor) } == true, "bare time: anchor day")
        check(hm(d.date) == "16:00", "bare time: 16:00")

        // 4. Follow-ups change the draft.
        let base = await AppointmentExtractor.extract(from: "Dentist on 20 Nov 2026 at 3pm")
        d = await AppointmentExtractor.revise(base, with: "make it 4:30pm")
        show(d)
        check(d.date.map { cal.component(.day, from: $0) } == 20 && hm(d.date) == "16:30",
              "revise: time only keeps the day")
        d = await AppointmentExtractor.revise(base, with: "move it to 25 Nov 2026")
        check(d.date.map { cal.component(.day, from: $0) } == 25 && hm(d.date) == "15:00",
              "revise: day only keeps the time")
        d = await AppointmentExtractor.revise(base, with: "ends at 5pm")
        check(hm(d.date) == "15:00" && hm(d.end) == "17:00", "revise: end time")

        // 5. No date → the draft is not ready.
        d = await AppointmentExtractor.extract(from: "Coffee with the NUS team")
        show(d)
        check(d.date == nil && !d.isReady, "no date: not ready to add")

        // 6. Date-only: stored at midnight, no time.
        d = await AppointmentExtractor.extract(from: "Company retreat on 4 Dec 2026")
        show(d)
        check(!d.hasTime && hm(d.date) == "00:00", "date only: all day at midnight")

        // 7. An email screenshot (Vision text): the send stamp is not the meeting time,
        //    and "Re:" is dropped from the subject.
        let email = """
            Re: Request for Proposal – Custom AI-Enabled Training Management System
            External
            Inbox x
            stylusyeo@advancesafe.com.sg
            5:52 PM (4 hours ago)
            to me, Soik, jaye, Qistina
            Dear Dr Alfred,
            I would like to confirm this meeting on Monday 1pm.
            Thank you
            Best regards
            Stylus Yeo
            Principal Director
            """
        d = await AppointmentExtractor.extract(from: email, request: "add this to appointment")
        show(d)
        check(d.date.map { cal.component(.weekday, from: $0) } == 2, "email: on a Monday")
        check(d.hasTime && hm(d.date) == "13:00", "email: 1pm, not the 5:52 PM send stamp")
        check(!d.title.lowercased().contains("add this"), "email: the request is not the title")
        check(!d.title.hasPrefix("Re:"), "email: no Re: prefix")
        check(d.isReady, "email: ready to add")

        // 8. Confirmation phrases.
        check(AppointmentExtractor.isConfirmation("add this to appointment"), "confirm: add this to appointment")
        check(AppointmentExtractor.isConfirmation("Yes, save it"), "confirm: yes, save it")
        check(!AppointmentExtractor.isConfirmation("add Sam to it"), "confirm: not an edit")
        check(!AppointmentExtractor.isConfirmation("add this at 3pm"), "confirm: not with a time")

        // 9. A time said alongside a screenshot overrides the screenshot's.
        d = await AppointmentExtractor.extract(from: email, request: "add this, it's at 3pm")
        check(hm(d.date) == "15:00", "request: spoken time overrides")

        print(failures == 0 ? "\nAll passed" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
