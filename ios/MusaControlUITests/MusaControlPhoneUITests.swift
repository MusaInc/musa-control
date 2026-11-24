import XCTest

/// iPhone: the same workspace one panel at a time, plus Agents, Desktop and
/// More tabs. Runs only on an iPhone simulator in CI.
final class MusaControlPhoneUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "iPhone-only layout tests")
    }

    func launch(orientation: UIDeviceOrientation = .portrait, appearance: String = "dark", extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchArguments = ["-UITestFixtures", "-appearance", appearance, "-project", "cityswing", "-desktop.active", "NO"] + extra
        app.launch()
        return app
    }

    func snap(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = "iphone-" + name
        a.lifetime = .keepAlways
        add(a)
    }

    func testTabs() {
        for appearance in ["dark", "light"] {
            let app = launch(appearance: appearance)
            for t in ["workspace", "agents", "desktop", "more"] {
                let b = app.buttons["tab.\(t)"]
                XCTAssertTrue(b.waitForExistence(timeout: 8), "tab.\(t)")
                b.tap(); sleep(2)
                snap(app, "\(appearance)-tab-\(t)")
            }
            app.terminate()
        }
    }

    func testPanelsOneAtATime() {
        let app = launch(extra: ["-preset", "code"])
        XCTAssertTrue(app.buttons["page.editor"].waitForExistence(timeout: 8))
        for p in ["editor", "terminal", "agent"] {
            let b = app.buttons["page.\(p)"]
            if b.waitForExistence(timeout: 3) { b.tap(); sleep(2); snap(app, "page-\(p)") }
        }
    }

    func testAgentListThenDetail() {
        let app = launch()
        app.buttons["tab.agents"].tap(); sleep(2)
        snap(app, "agents-list")
        let first = app.cells.firstMatch
        if first.waitForExistence(timeout: 5) { first.tap(); sleep(2); snap(app, "agent-detail") }
    }

    func testLandscape() {
        let app = launch(orientation: .landscapeLeft)
        sleep(3)
        snap(app, "landscape-workspace")
        XCUIDevice.shared.orientation = .portrait
    }
}
