import XCTest

/// iPhone: four tabs — Agents, Terminal, Files, Settings.
final class MusaControlPhoneUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "iPhone-only layout tests")
    }

    func launch(orientation: UIDeviceOrientation = .portrait, appearance: String = "dark", extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchArguments = ["-UITestFixtures", "-appearance", appearance, "-desktop.active", "NO"] + extra
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
            for t in ["agents", "terminal", "files", "settings"] {
                let b = app.buttons["tab.\(t)"]
                XCTAssertTrue(b.waitForExistence(timeout: 8), "tab.\(t)")
                b.tap(); sleep(2)
                snap(app, "\(appearance)-tab-\(t)")
            }
            app.terminate()
        }
    }

    func testAgentListThenDetail() {
        let app = launch()
        app.buttons["tab.agents"].tap()
        let agents = app.segmentedControls["studio.workspace"].buttons["Agents"]
        XCTAssertTrue(agents.waitForExistence(timeout: 8))
        agents.tap()
        sleep(2)
        snap(app, "agents-list")
        let first = app.cells.firstMatch
        if first.waitForExistence(timeout: 5) { first.tap(); sleep(2); snap(app, "agent-detail") }
    }

    func testLandscape() {
        let app = launch(orientation: .landscapeLeft)
        sleep(3)
        snap(app, "landscape-agents")
        XCUIDevice.shared.orientation = .portrait
    }
}
