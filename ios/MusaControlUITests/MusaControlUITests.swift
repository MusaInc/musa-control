import XCTest

/// Drives the simplified iPad app with fixture data captured from the real
/// gateway and saves screenshots of Agents, Terminal, Files, Settings and
/// contextual sheets for visual review.
final class MusaControlUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    func launch(orientation: UIDeviceOrientation = .landscapeLeft, appearance: String = "dark", extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchArguments = ["-UITestFixtures", "-appearance", appearance, "-desktop.active", "NO"] + extra
        app.launch()
        XCUIDevice.shared.orientation = orientation
        let landscape = orientation == .landscapeLeft || orientation == .landscapeRight
        let settled = NSPredicate { _, _ in
            let frame = app.windows.firstMatch.frame
            return frame.width > 0 && (landscape ? frame.width > frame.height : frame.height > frame.width)
        }
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: settled, object: nil)], timeout: 10) == .completed)
        return app
    }

    func snap(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    /// Agents is the centre of the app in both orientations and appearances.
    func testAgentsCenterpiece() {
        for (orientation, tag) in [(UIDeviceOrientation.landscapeLeft, "landscape"), (.portrait, "portrait")] {
            for appearance in ["dark", "light"] {
                let app = launch(orientation: orientation, appearance: appearance)
                XCTAssertTrue(el(app, "nav.agents").waitForExistence(timeout: 10), "agents rail item")
                sleep(3)
                snap(app, "\(tag)-\(appearance)-agents")
                app.terminate()
            }
        }
    }

    func testStudioOpensContextualFilesAndBuilds() {
        let app = launch()
        XCTAssertTrue(el(app, "studio.overview").waitForExistence(timeout: 10))
        let files = el(app, "studio.files")
        XCTAssertTrue(files.waitForExistence(timeout: 10))
        files.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10))
        snap(app, "studio-files")
        app.buttons["Done"].tap()

        let builds = el(app, "studio.builds")
        XCTAssertTrue(builds.waitForExistence(timeout: 10))
        builds.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10))
        snap(app, "studio-builds")
        app.buttons["Done"].tap()
        XCTAssertTrue(el(app, "studio.overview").exists)
    }

    func testLiveWorkOpensNativeChatGPTBrowser() {
        let app = launch()
        let liveWork = app.segmentedControls["studio.workspace"].buttons["Live Work"]
        XCTAssertTrue(liveWork.waitForExistence(timeout: 10))
        liveWork.tap()
        let browser = app.buttons["liveWork.browser"]
        XCTAssertTrue(browser.waitForExistence(timeout: 10))
        browser.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        snap(app, "studio-native-chatgpt-browser")
    }

    /// Four-section navigation: Agents, Terminal, Files, Settings.
    func testFourSections() {
        let app = launch()
        for s in ["agents", "terminal", "files", "settings"] {
            let b = el(app, "nav.\(s)")
            XCTAssertTrue(b.waitForExistence(timeout: 8), "nav.\(s)")
            b.tap(); sleep(2)
            snap(app, "section-\(s)")
        }
    }

    /// Physical keyboard navigation: ⌘1–4 switch sections, ⌘K opens quick switcher.
    func testKeyboardShortcuts() {
        let app = launch()
        XCTAssertTrue(el(app, "nav.agents").waitForExistence(timeout: 10))
        app.typeKey("3", modifierFlags: .command); sleep(1)
        snap(app, "keyboard-files")
        app.typeKey("1", modifierFlags: .command); sleep(1)
        snap(app, "keyboard-agents")
        app.typeKey("k", modifierFlags: .command); sleep(1)
        snap(app, "keyboard-switcher")
    }

    /// Machines & AI sheet opens from the bottom of the rail.
    func testMachinesSheet() {
        let app = launch()
        el(app, "machine.switcher").tap()
        XCTAssertTrue(app.staticTexts["Musa Studios VPS"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Claude Code"].waitForExistence(timeout: 8))
        snap(app, "machines-sheet")
        app.buttons["Done"].firstMatch.tap()
    }

    /// First run for a new user: welcome → add a computer → SSH form.
    func testOnboardingAndAddComputer() {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance, extra: ["-onboarding"])
            XCTAssertTrue(app.buttons["welcome.ssh"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["welcome.email"].exists)
            snap(app, "onboarding-welcome-\(appearance)")
            if appearance == "light" {
                app.buttons["welcome.ssh"].tap()
                XCTAssertTrue(app.buttons["add.linux"].waitForExistence(timeout: 5))
                app.buttons["add.linux"].tap()
                XCTAssertTrue(app.textFields["ssh.host"].waitForExistence(timeout: 5))
                snap(app, "onboarding-ssh")
            }
            app.terminate()
        }
    }
}
