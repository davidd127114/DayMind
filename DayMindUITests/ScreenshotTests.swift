import XCTest

/// Captures the real rendered screens on the simulator (light, dark, largest accessibility text)
/// so the design can be inspected from the CI artifacts. Also drives the core typed flow.
final class ScreenshotTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-daymind-ui-testing"] + extra
        app.launch()
        return app
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitForButler(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["butlerMic"].waitForExistence(timeout: 20), "Butler screen did not appear")
    }

    func test01ButlerAndBookLight() {
        let app = launch(["-daymind-theme", "light"])
        waitForButler(app)
        snap(app, "01-butler-light")
        app.buttons["openMyBook"].tap()
        XCTAssertTrue(app.navigationBars["My Book"].waitForExistence(timeout: 10))
        snap(app, "02-book-light")
        app.buttons["filter-memories"].tap()
        snap(app, "03-book-memories-light")
    }

    func test02ButlerAndBookDark() {
        let app = launch(["-daymind-theme", "dark"])
        waitForButler(app)
        snap(app, "04-butler-dark")
        app.buttons["openMyBook"].tap()
        XCTAssertTrue(app.navigationBars["My Book"].waitForExistence(timeout: 10))
        snap(app, "05-book-dark")
    }

    func test03LargestAccessibilityText() {
        let app = launch(["-daymind-theme", "light", "-daymind-textsize", "xxxl"])
        waitForButler(app)
        snap(app, "06-butler-xxxl")
        app.buttons["openMyBook"].tap()
        XCTAssertTrue(app.navigationBars["My Book"].waitForExistence(timeout: 10))
        snap(app, "07-book-xxxl")
    }

    func test04TypedRequestProducesConfirmationCard() {
        let app = launch(["-daymind-theme", "light", "-daymind-demo-request", "Remind me tomorrow at 3 PM to call John about the roof"])
        waitForButler(app)
        let card = app.staticTexts["Reminder saved"]
        XCTAssertTrue(card.waitForExistence(timeout: 20), "confirmation card did not appear")
        XCTAssertTrue(app.staticTexts["Call John about the roof"].exists)
        snap(app, "08-confirmation-light")
        // Undo must be offered for a genuine reversal (create → delete).
        XCTAssertTrue(app.buttons["Undo"].exists)
    }

    func test05NeedsClarificationState() {
        let app = launch(["-daymind-theme", "light", "-daymind-demo-request", "Remind me later to call the bank"])
        waitForButler(app)
        XCTAssertTrue(app.staticTexts["One question"].waitForExistence(timeout: 20))
        snap(app, "09-clarification-light")
    }

    func test06UnprocessedRequestGoesToNeedsAttention() {
        let app = launch(["-daymind-theme", "dark", "-daymind-demo-request", "purple elephants dancing in the rain"])
        waitForButler(app)
        XCTAssertTrue(app.staticTexts["Kept for you to finish"].waitForExistence(timeout: 20))
        snap(app, "10-needs-attention-card-dark")
        XCTAssertTrue(app.buttons["needsAttention"].waitForExistence(timeout: 20))
        app.buttons["needsAttention"].tap()
        XCTAssertTrue(app.navigationBars["My Book"].waitForExistence(timeout: 10))
        snap(app, "11-book-needs-attention-dark")
    }
}
