import XCTest

final class AppointmentEditTests: XCTestCase {
    private func launchUpcoming() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-seedSampleData", "-openUpcoming"]
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// "Reply / comment" opens an inline box (not the edit form) and the comment is kept.
    func testReplyCommentsInline() {
        let app = launchUpcoming()
        let reply = app.buttons["appointment.reply"].firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 10))
        reply.tap()

        let field = app.textFields["appointment.commentText"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "inline comment box opens")
        XCTAssertFalse(app.navigationBars["Edit Appointment"].exists, "edit form must not open")
        field.tap()
        field.typeText("Moved to next Tuesday")
        app.buttons["appointment.postComment"].firstMatch.tap()

        XCTAssertTrue(element(app, containing: "Moved to next Tuesday").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, containing: "Partner check-in").exists, "appointment kept, not ticked")
        XCTAssertFalse(field.exists, "box closes after posting")
    }

    /// Typing an edit in the capture bar changes the existing appointment, no duplicate.
    func testCaptureBarReschedulesExistingAppointment() {
        let app = launchUpcoming()
        let bar = app.textFields.matching(NSPredicate(format: "placeholderValue CONTAINS 'Lunch with Sam'")).firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        bar.tap()
        bar.typeText("move Dentist to 5pm")
        app.buttons["Send"].tap()

        XCTAssertTrue(element(app, containing: "Moved “Dentist”").waitForExistence(timeout: 15),
                      "confirmation appears")
        // Narrow to Dentist with search (the row may sit below the fold of the lazy list).
        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText("Dentist")
        XCTAssertTrue(element(app, containing: "Dentist,").waitForExistence(timeout: 5))
        let dentists = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Dentist,'"))
        XCTAssertEqual(dentists.count, 1, "no duplicate Dentist row")
        XCTAssertTrue(dentists.firstMatch.label.contains("5:00"), "Dentist now at 5 pm: \(dentists.firstMatch.label)")
    }
}
