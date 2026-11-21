import XCTest

@MainActor
final class PreRideReadyUITests: XCTestCase {
    func testReadyPanelAndFullWidthStartKeepSimulatedRideAvailable() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-simulationMode", "YES", "-disableLiveActivity", "YES"]
        app.launch()

        let disclosure = app.staticTexts["Coordinates or plus code"]
        XCTAssertTrue(reveal(disclosure, in: app))
        disclosure.tap()
        let field = app.textFields["pasteField"]
        XCTAssertTrue(reveal(field, in: app))
        field.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 5) { field.tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        field.typeText("12.9716, 77.5946")
        app.buttons["usePastedButton"].tap()
        XCTAssertTrue(app.buttons["confirmDestinationButton"].waitForExistence(timeout: 5))
        app.buttons["confirmDestinationButton"].tap()

        let option = app.buttons["routeOption-0"]
        XCTAssertTrue(reveal(option, in: app, up: false))
        option.tap()

        let route = app.descendants(matching: .any)["readyRouteStatus"]
        let position = app.descendants(matching: .any)["readyPositionStatus"]
        let bike = app.descendants(matching: .any)["readyBikeStatus"]
        let audio = app.descendants(matching: .any)["readyAudioStatus"]
        XCTAssertTrue(reveal(route, in: app))
        XCTAssertTrue(route.label.contains("Synthetic demo route"))
        XCTAssertTrue(reveal(position, in: app))
        XCTAssertTrue(position.label.contains("Simulated position"))
        XCTAssertTrue(reveal(bike, in: app))
        XCTAssertTrue(reveal(audio, in: app))
        XCTAssertTrue(audio.label.contains("Output:"))

        let start = app.buttons["startNavigationButton"]
        XCTAssertTrue(reveal(start, in: app, up: false))
        XCTAssertTrue(start.isEnabled)
        XCTAssertEqual(app.buttons.matching(identifier: "startNavigationButton").count, 1)
        XCTAssertFalse(app.buttons["readyTestAudioButton"].exists)
        XCTAssertGreaterThanOrEqual(start.frame.width, app.frame.width * 0.8)
        XCTAssertGreaterThanOrEqual(start.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(start.frame.maxX, app.frame.maxX)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "ready-full-width-start"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        start.tap()
        XCTAssertTrue(app.descendants(matching: .any)["currentTurn"].waitForExistence(timeout: 5))
        let stop = app.buttons["stopButton"]
        XCTAssertTrue(reveal(stop, in: app))
        stop.tap()
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, up: Bool = true) -> Bool {
        if element.waitForExistence(timeout: 3), element.isHittable { return true }
        for _ in 0..<8 {
            if element.exists && element.isHittable { return true }
            up ? app.swipeUp() : app.swipeDown()
        }
        return element.exists && element.isHittable
    }
}
