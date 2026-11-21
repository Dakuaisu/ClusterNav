import XCTest

final class RideRecapUITests: XCTestCase {
    @MainActor
    func testRecordingDisclosureCanBeCancelled() {
        continueAfterFailure = false
        let app = XCUIApplication()
        // The argument domain overrides the initial state without changing stored consent.
        app.launchArguments += ["-simulationMode", "YES", "-disableLiveActivity", "YES",
                                "-rideTracksEnabled", "NO"]
        app.launch()

        XCTAssertTrue(app.staticTexts["simulationBadge"].waitForExistence(timeout: 10))
        let history = app.buttons["History"]
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        history.tap()

        let recaps = app.buttons["historyRecapsLink"]
        XCTAssertTrue(recaps.waitForExistence(timeout: 5))
        recaps.tap()

        let recording = app.switches["trackRecordingToggle"]
        XCTAssertTrue(recording.waitForExistence(timeout: 5))
        XCTAssertEqual(recording.value as? String, "0")
        attachScreenshot(of: app, named: "recaps-recording-off")

        recording.switches.firstMatch.tap()
        let disclosure = app.alerts["Record GPS tracks?"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        let message = "Future rides can save precise locations, timestamps and GPS accuracy on this phone. "
            + "Recording starts with your next new ride. Turning it off stops recording but does not delete saved tracks."
        XCTAssertTrue(disclosure.staticTexts.matching(NSPredicate(format: "label == %@", message)).firstMatch.exists)
        XCTAssertTrue(disclosure.buttons["Turn on recording"].exists)
        XCTAssertTrue(disclosure.buttons["Cancel"].exists)
        attachScreenshot(of: app, named: "recaps-recording-disclosure")

        disclosure.buttons["Cancel"].tap()
        XCTAssertTrue(disclosure.waitForNonExistence(timeout: 5))
        XCTAssertEqual(recording.value as? String, "0", "Cancellation must not turn recording on")
        attachScreenshot(of: app, named: "recaps-after-cancellation")

        recording.switches.firstMatch.tap()
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5), "Cancellation must leave the disclosure required")
        disclosure.buttons["Cancel"].tap()
        XCTAssertTrue(disclosure.waitForNonExistence(timeout: 5))
        XCTAssertEqual(recording.value as? String, "0")
    }

    @MainActor
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
