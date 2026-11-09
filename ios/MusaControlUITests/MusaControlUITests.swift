import XCTest

/// Drives the app with fixture data captured from the real gateway and keeps
/// a screenshot of every section in both orientations for visual review.
final class MusaControlUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    func launch(_ section: String, orientation: UIDeviceOrientation, appearance: String = "dark", extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchArguments = ["-UITestFixtures", "-section", section, "-appearance", appearance] + extra
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
            for appearance in ["dark", "light"] {
                let sections = orientation == .portrait && appearance == "light" ? ["home", "agents", "settings"] : ["home", "workspaces", "agents", "terminal", "files", "visuals", "git", "settings"]
                for s in sections {
                    let app = launch(s, orientation: orientation, appearance: appearance)
                    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
                    sleep(3)
                    snap(app, "\(tag)-\(appearance)-\(s)")
                    app.terminate()
                }
            }
        }
    }

    /// The reported bug: a dismissed sidebar disappeared with no way back.
    /// Collapse → navigate → restart → navigation still reachable → restore.
    func testSidebarCanAlwaysBeRestored() {
        var app = launch("home", orientation: .landscapeLeft, extra: ["-sidebar.expanded", "YES"])
        let toggle = app.buttons["sidebar.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 6), "sidebar toggle visible")
        snap(app, "sidebar-1-expanded")
        toggle.tap(); sleep(1)
        snap(app, "sidebar-2-collapsed-rail")
        XCTAssertTrue(app.buttons["sidebar.agents"].exists, "rail keeps navigation when collapsed")
        app.buttons["sidebar.agents"].tap(); sleep(1)
        XCTAssertTrue(app.buttons["sidebar.toggle"].exists, "toggle survives switching screens")
        app.terminate()

        // Restart: the collapsed preference is kept, navigation is still there.
        app = launch("agents", orientation: .landscapeLeft)
        XCTAssertTrue(app.buttons["sidebar.toggle"].waitForExistence(timeout: 6), "toggle after restart")
        XCTAssertTrue(app.buttons["sidebar.files"].exists, "rail after restart")
        snap(app, "sidebar-3-after-restart")
        app.buttons["sidebar.toggle"].tap(); sleep(1)
        XCTAssertTrue(app.staticTexts["Musa Control"].waitForExistence(timeout: 3), "full sidebar restored")
        snap(app, "sidebar-4-restored")
        app.terminate()

        // Portrait: rail and toggle are still reachable.
        app = launch("home", orientation: .portrait)
        XCTAssertTrue(app.buttons["sidebar.toggle"].waitForExistence(timeout: 6), "toggle in portrait")
        XCTAssertTrue(app.buttons["sidebar.settings"].exists)
        snap(app, "sidebar-5-portrait")
        app.terminate()
    }

    func testAgentActivityRendering() {
        for appearance in ["dark", "light"] {
            let app = launch("agents", orientation: .landscapeLeft, appearance: appearance)
            sleep(4)
            snap(app, "agent-activity-\(appearance)")
            app.swipeDown(); sleep(1)
            snap(app, "agent-activity-scrolled-\(appearance)")
            app.terminate()
        }
        let app = launch("agents", orientation: .portrait)
        sleep(4)
        snap(app, "agent-activity-portrait")
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

    /// Active agents in the sidebar open a live studio that replays real work.
    func testAgentStudio() {
        for appearance in ["dark", "light"] {
            let app = launch("home", orientation: .landscapeLeft, appearance: appearance, extra: ["-sidebar.expanded", "YES"])
            let row = app.buttons["sidebar.agent.codex:sample-2"]
            XCTAssertTrue(row.waitForExistence(timeout: 8), "running agent listed in the sidebar")
            snap(app, "studio-sidebar-\(appearance)")
            row.tap()
            XCTAssertTrue(app.buttons["studio.close"].waitForExistence(timeout: 6), "studio opens")
            for t in [2, 5, 9] { sleep(t == 2 ? 2 : 3); snap(app, "studio-\(appearance)-\(t)s") }
            app.buttons["studio.close"].tap(); sleep(1)
            XCTAssertFalse(app.buttons["studio.close"].exists, "studio closes")
            app.terminate()
        }
        let app = launch("home", orientation: .portrait, extra: ["-studio", "claude:sample-1"])
        sleep(6)
        snap(app, "studio-portrait-approval")
    }

    /// Command Deck: live tiles sized by activity, approval up front; a tile
    /// grows into the studio and shrinks back.
    func testCommandDeck() {
        for (orientation, tag) in [(UIDeviceOrientation.landscapeLeft, "landscape"), (.portrait, "portrait")] {
            for appearance in ["dark", "light"] {
                let app = launch("deck", orientation: orientation, appearance: appearance)
                XCTAssertTrue(app.buttons["deck.tile.claude:sample-1"].waitForExistence(timeout: 8), "approval tile on the deck")
                sleep(3)
                snap(app, "deck-\(tag)-\(appearance)")
                if appearance == "dark" { sleep(6); snap(app, "deck-\(tag)-\(appearance)-later") }
                app.terminate()
            }
        }
        let app = launch("deck", orientation: .landscapeLeft)
        let tile = app.buttons["deck.tile.codex:sample-2"]
        XCTAssertTrue(tile.waitForExistence(timeout: 8), "working agent has a tile")
        XCTAssertTrue(app.buttons["deck.chip.claude:sample-4"].exists, "ended agent settles into a chip")
        tile.tap()
        snap(app, "deck-expanding")
        XCTAssertTrue(app.buttons["studio.close"].waitForExistence(timeout: 6), "tile expands into the studio")
        sleep(5)
        snap(app, "deck-expanded-studio")
        app.buttons["studio.close"].tap()
        XCTAssertTrue(app.buttons["deck.tile.codex:sample-2"].waitForExistence(timeout: 5), "studio shrinks back into the deck")
        sleep(1)
        snap(app, "deck-after-close")
    }
}
