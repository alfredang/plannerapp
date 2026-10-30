import XCTest

final class AppointmentChatTests: XCTestCase {
    private func element(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// + on Appointments opens the chat; a typed request becomes a draft card, and
    /// "add this to appointment" adds it.
    func testChatDraftsAndAddsAppointment() {
        let app = XCUIApplication()
        app.launchArguments = ["-seedSampleData", "-openAppointments"]
        app.launch()

        let plus = app.buttons["Add item"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 10))
        plus.tap()
        XCTAssertTrue(app.navigationBars["New Appointment"].waitForExistence(timeout: 5))

        let field = app.textFields["appointmentChat.input"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Proposal review with Stylus Yeo on 9 Nov 2026 at 1pm")
        app.buttons["appointmentChat.send"].tap()

        let addButton = app.buttons["appointmentChat.add"].firstMatch
        XCTAssertTrue(addButton.waitForExistence(timeout: 20), "draft card appears")
        XCTAssertTrue(addButton.isEnabled, "draft is ready to add")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "appointment-chat-draft"
        shot.lifetime = .keepAlways
        add(shot)

        field.tap()
        field.typeText("add this to appointment")
        app.buttons["appointmentChat.send"].tap()

        let closed = expectation(for: NSPredicate(format: "exists == false"),
                                 evaluatedWith: app.navigationBars["New Appointment"])
        wait(for: [closed], timeout: 10)
        // Narrow with search: the new row may sit below the fold of the lazy list.
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Stylus")
        XCTAssertTrue(element(app, containing: "Proposal review with Stylus Yeo").waitForExistence(timeout: 10),
                      "appointment is in the list")
    }
}
