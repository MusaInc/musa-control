import XCTest

/// Drives the app with fixture data captured from the real gateway and keeps
/// a screenshot of every section in both orientations for visual review.
final class MusaControlUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    func launch(_ section: String, orientation: UIDeviceOrientation) -> XCUIApplication {
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchArguments = ["-UITestFixtures", "-section", section]
        app.launch()
        return app
    }

    func snap(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func testEverySectionLandscapeAndPortrait() {
        for (orientation, tag) in [(UIDeviceOrientation.landscapeLeft, "landscape"), (.portrait, "portrait")] {
            for s in ["home", "workspaces", "agents", "terminal", "files", "visuals", "git", "settings"] {
                let app = launch(s, orientation: orientation)
                XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
                sleep(3)
                snap(app, "\(tag)-\(s)")
                app.terminate()
            }
        }
    }

    func testNavigationAndLauncher() {
        let app = launch("home", orientation: .landscapeLeft)
        sleep(2)
        for s in ["agents", "files", "git", "visuals"] {
            let b = app.buttons["sidebar.\(s)"]
            if b.waitForExistence(timeout: 5) { b.tap(); sleep(1); snap(app, "nav-\(s)") } else { XCTFail("sidebar.\(s) missing") }
        }
        app.buttons["sidebar.home"].tap()
        let newTask = app.buttons["home.newTask"]
        XCTAssertTrue(newTask.waitForExistence(timeout: 5))
        newTask.tap()
        XCTAssertTrue(app.buttons["launcher.start"].waitForExistence(timeout: 5))
        snap(app, "launcher")
    }

    func testWorkspaceOpensWithPanels() {
        let app = launch("workspaces", orientation: .landscapeLeft)
        let card = app.buttons["project.cityswing"]
        if card.waitForExistence(timeout: 6) { card.tap() }
        sleep(3)
        snap(app, "workspace-cityswing")
        XCTAssertTrue(app.buttons["workspace.addPanel"].waitForExistence(timeout: 5))
    }
}
