import XCTest

/// iPhone layout: bottom tab bar + More drawer, one pane at a time with Back,
/// and a screenshot of every section (portrait, both appearances, plus a few
/// landscape) for visual review. Runs only on an iPhone simulator in CI.
final class MusaControlPhoneUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "iPhone-only layout tests")
    }

    func launch(_ section: String, orientation: UIDeviceOrientation = .portrait, appearance: String = "dark", extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchArguments = ["-UITestFixtures", "-section", section, "-appearance", appearance] + extra
        app.launch()
        return app
    }

    func snap(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = "iphone-" + name
        a.lifetime = .keepAlways
        add(a)
    }

    func testEverySectionPortrait() {
        for appearance in ["dark", "light"] {
            let sections = appearance == "light" ? ["home", "agents", "git", "settings"] : ["home", "workspaces", "agents", "terminal", "files", "visuals", "git", "settings"]
            for s in sections {
                let app = launch(s, appearance: appearance)
                XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
                XCTAssertTrue(app.buttons["tab.home"].waitForExistence(timeout: 6), "tab bar on \(s)")
                sleep(3)
                snap(app, "portrait-\(appearance)-\(s)")
                app.terminate()
            }
        }
    }

    func testLandscape() {
        for s in ["home", "agents", "terminal"] {
            let app = launch(s, orientation: .landscapeLeft)
            sleep(3)
            snap(app, "landscape-\(s)")
            app.terminate()
        }
        XCUIDevice.shared.orientation = .portrait
    }

    /// Tabs switch sections; More opens every other section and the agents.
    func testTabBarAndMore() {
        let app = launch("home")
        for t in ["agents", "terminal", "files", "home"] {
            let b = app.buttons["tab.\(t)"]
            XCTAssertTrue(b.waitForExistence(timeout: 5), "tab.\(t)")
            b.tap(); sleep(1)
            snap(app, "tab-\(t)")
        }
        app.buttons["tab.more"].tap()
        let git = app.buttons["sidebar.git"]
        XCTAssertTrue(git.waitForExistence(timeout: 4), "More shows every section")
        snap(app, "more-drawer")
        git.tap(); sleep(1)
        XCTAssertFalse(app.buttons["sidebar.git"].isHittable, "drawer closes after navigating")
        snap(app, "more-git")

        app.buttons["tab.home"].tap()
        let newTask = app.buttons["home.newTask"]
        XCTAssertTrue(newTask.waitForExistence(timeout: 5))
        newTask.tap()
        XCTAssertTrue(app.buttons["launcher.start"].waitForExistence(timeout: 5), "launcher fits on a phone")
        snap(app, "launcher")
    }

    /// Lists fill the screen; picking an item shows it with Back.
    func testListThenDetail() {
        let app = launch("agents")
        let row = app.staticTexts["Sample: add a pause menu"]
        XCTAssertTrue(row.waitForExistence(timeout: 8), "agent list")
        snap(app, "agents-list")
        row.tap(); sleep(2)
        XCTAssertTrue(app.buttons["back"].waitForExistence(timeout: 4), "detail has Back")
        XCTAssertTrue(app.textViews["agent.composer"].exists || app.textFields["agent.composer"].exists, "composer visible")
        snap(app, "agent-detail")
        app.buttons["back"].tap(); sleep(1)
        XCTAssertTrue(app.staticTexts["Sample: add a pause menu"].waitForExistence(timeout: 4), "back to the list")
        app.terminate()

        // Approval waiting: the card is reachable on a phone.
        let a2 = launch("agents")
        let waiting = a2.staticTexts["Sample: smooth the swing camera"]
        if waiting.waitForExistence(timeout: 8) { waiting.tap(); sleep(2); snap(a2, "agent-approval") }
        a2.terminate()

        // Git: history list → commit diff → Back.
        let g = launch("git")
        sleep(3)
        snap(g, "git-changes")
        let history = g.buttons["History"]
        if history.waitForExistence(timeout: 4) {
            history.tap(); sleep(2)
            snap(g, "git-history")
            let firstCell = g.cells.firstMatch
            if firstCell.waitForExistence(timeout: 4) {
                firstCell.tap(); sleep(2)
                XCTAssertTrue(g.buttons["back"].waitForExistence(timeout: 4), "commit diff has Back")
                snap(g, "git-commit-diff")
            }
        }
    }

    func testAgentStudioOnPhone() {
        let app = launch("home", extra: ["-studio", "codex:sample-2"])
        XCTAssertTrue(app.buttons["studio.close"].waitForExistence(timeout: 8), "studio opens on a phone")
        for t in [2, 6] { sleep(UInt32(t == 2 ? 2 : 4)); snap(app, "studio-\(t)s") }
    }
}
