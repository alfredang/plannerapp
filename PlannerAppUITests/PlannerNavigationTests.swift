import XCTest

final class PlannerNavigationTests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-seedSampleData"]
        app.launch()
        return app
    }

    func testDailyBriefIsDefaultAndLegacyTitleIsRenamed() {
        let app = launch()
        XCTAssertTrue(app.buttons["planner.updates"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["planner.tasks"].exists)
        XCTAssertTrue(app.buttons["planner.appointments"].exists)
        XCTAssertTrue(app.segmentedControls["updates.scope"].buttons["Morning Brief"].isSelected)
        XCTAssertTrue(app.staticTexts["Morning Brief Today"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Morning Updates Today"].exists)
        XCTAssertTrue(app.staticTexts["Yesterday"].exists)
        app.staticTexts["Morning Brief Today"].tap()
        XCTAssertTrue(app.navigationBars["Morning Brief Today"].waitForExistence(timeout: 5))
    }

    func testOtherUpdatesAndTaskAppointmentNavigation() {
        let app = launch()
        let scope = app.segmentedControls["updates.scope"]
        XCTAssertTrue(scope.waitForExistence(timeout: 10))
        scope.buttons["Other Updates"].tap()
        XCTAssertTrue(app.staticTexts["Weekly Strategy Review"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Morning Brief Today"].exists)
        app.buttons["planner.tasks"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'All Tasks'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Submit tender proposal'")).firstMatch.exists)
        app.buttons["planner.appointments"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Upcoming'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Lunch with Sam'")).firstMatch.exists)
        app.buttons["planner.updates"].tap()
        XCTAssertTrue(app.segmentedControls["updates.scope"].buttons["Morning Brief"].isSelected)
    }
}
