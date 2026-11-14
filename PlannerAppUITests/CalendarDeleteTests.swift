import XCTest

final class CalendarDeleteTests: XCTestCase {
    private func element(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// Month view: swiping one of the selected day's appointments left shows Delete, and
    /// tapping it removes that appointment only.
    func testSwipeLeftDeletesAppointmentInMonthView() {
        let app = XCUIApplication()
        app.launchArguments = ["-seedSampleData", "-openCalendar"]
        app.launch()

        let monthTab = app.buttons["Month"].firstMatch
        XCTAssertTrue(monthTab.waitForExistence(timeout: 10))
        monthTab.tap()

        // The title is on screen twice: the chip in the month grid, then the agenda row.
        let titles = app.staticTexts.matching(identifier: "Lunch with Sam")
        XCTAssertTrue(titles.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(titles.count, 2, "today's agenda lists the appointment")
        let row = titles.element(boundBy: 1)
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: -0.4, dy: 0.5)))

        let delete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "swiping left reveals Delete")
        delete.tap()

        XCTAssertTrue(app.staticTexts["Lunch with Sam"].firstMatch.waitForNonExistence(timeout: 5),
                      "the appointment is removed from the agenda and the grid")
        XCTAssertTrue(element(app, containing: "Client call").exists, "other appointments are kept")
    }
}
