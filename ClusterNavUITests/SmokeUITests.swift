import XCTest

/// One short end-to-end flow, run on its own by `scripts/test.sh smoke`: enter a
/// destination, check the pin that was understood, start a simulated ride, see a
/// turn, end the ride. It shares nothing with the larger suite.
@MainActor
final class SmokeUITests: XCTestCase {
    func testEnterDestinationCheckPinRideAndEnd() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-simulationMode", "YES", "-disableLiveActivity", "YES"]
        app.launch()

        let disclosure = app.staticTexts["Coordinates or plus code"]
        XCTAssertTrue(reveal(disclosure, in: app), "destination picker did not appear")
        disclosure.tap()
        let field = app.textFields["pasteField"]
        XCTAssertTrue(reveal(field, in: app))
        field.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 5) { field.tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        field.typeText("12.9716, 77.5946")
        app.buttons["usePastedButton"].tap()

        let pin = app.staticTexts["destinationCoordinate"]
        XCTAssertTrue(pin.waitForExistence(timeout: 5), "confirmation did not open")
        XCTAssertEqual(pin.label, "12.971600, 77.594600", "the proposed pin is not the entered destination")
        app.buttons["confirmDestinationButton"].tap()

        let start = app.buttons["startNavigationButton"]
        XCTAssertTrue(start.waitForExistence(timeout: 5), "route preview did not open")
        start.tap()
        XCTAssertTrue(app.descendants(matching: .any)["currentTurn"].waitForExistence(timeout: 10), "no turn was shown")

        let stop = app.buttons["stopButton"]
        XCTAssertTrue(reveal(stop, in: app))
        stop.tap()
        XCTAssertTrue(app.staticTexts["Coordinates or plus code"].waitForExistence(timeout: 5)
                      || reveal(app.staticTexts["Coordinates or plus code"], in: app),
                      "ending the ride did not return to the picker")
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        if element.waitForExistence(timeout: 5), element.isHittable { return true }
        for _ in 0..<6 {
            if element.exists && element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }
}
