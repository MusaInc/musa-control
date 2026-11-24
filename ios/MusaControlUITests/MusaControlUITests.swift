import XCTest

/// Drives the iPad app with fixture data captured from the real gateway and
/// keeps screenshots of the unified workspace for visual review.
final class MusaControlUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    func launch(orientation: UIDeviceOrientation = .landscapeLeft, appearance: String = "dark", project: String? = "cityswing", extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchArguments = ["-UITestFixtures", "-appearance", appearance, "-desktop.active", "NO", "-ws.navigatorVisible", "YES"]
            + (project.map { ["-project", $0] } ?? []) + extra
        app.launch()
        // Apply rotation after launch as well: SpringBoard and the app can
        // otherwise disagree about the screen orientation on the simulator.
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

    /// The workspace in both orientations and appearances, with each preset.
    func testWorkspaceLayouts() {
        for (orientation, tag) in [(UIDeviceOrientation.landscapeLeft, "landscape"), (.portrait, "portrait")] {
            for appearance in ["dark", "light"] {
                let app = launch(orientation: orientation, appearance: appearance)
                XCTAssertTrue(el(app, "workspace.project").waitForExistence(timeout: 10), "top bar")
                XCTAssertTrue(el(app, "status.keyboard").exists, "status bar shows keyboard focus")
                sleep(3)
                snap(app, "\(tag)-\(appearance)-workspace")
                if appearance == "dark" {
                    for p in ["code", "visual", "review", "agent"] where orientation == .landscapeLeft {
                        el(app, "preset.\(p)").tap(); sleep(2)
                        snap(app, "\(tag)-preset-\(p)")
                    }
                }
                app.terminate()
            }
        }
    }

    /// Navigator tabs: files, agents, source control; tapping the active
    /// one hides the navigator and it always comes back.
    func testNavigator() {
        let app = launch()
        for t in ["files", "agents", "git"] {
            let b = el(app, "nav.\(t)")
            XCTAssertTrue(b.waitForExistence(timeout: 8), "nav.\(t)")
            b.tap(); sleep(2)
            snap(app, "navigator-\(t)")
        }
        el(app, "nav.git").tap(); sleep(1)       // hide
        snap(app, "navigator-hidden")
        el(app, "nav.files").tap(); sleep(1)     // back
        XCTAssertTrue(el(app, "nav.files").isSelected || app.textFields.firstMatch.exists)
    }

    /// The agent panel follows real events; Steps, Files and Terminal show
    /// the same session's evidence; Follow pauses and resumes.
    func testAgentLivePanel() {
        let app = launch(extra: ["-preset", "agent"])
        XCTAssertTrue(el(app, "panel.agent").waitForExistence(timeout: 10))
        sleep(4)
        snap(app, "agent-live")
        for s in ["steps", "editor", "terminal"] {
            let b = el(app, "agent.stage.\(s)")
            if b.waitForExistence(timeout: 4) { b.tap(); sleep(2); snap(app, "agent-stage-\(s)") }
        }
        let follow = el(app, "agent.follow")
        if follow.exists { follow.tap(); sleep(1); snap(app, "agent-follow-resumed") }
    }

    /// Remote Desktop stays up (same session) across layouts and while
    /// sheets open over the workspace.
    func testRemoteDesktopPersists() {
        let app = launch()
        let toggle = el(app, "desktop.toggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 8))
        toggle.tap(); sleep(2)
        XCTAssertTrue(el(app, "desktop.display").waitForExistence(timeout: 5), "desktop toolbar")
        snap(app, "desktop-split")
        el(app, "desktop.layout.floating").tap(); sleep(2)
        XCTAssertTrue(el(app, "desktop.floating").waitForExistence(timeout: 4))
        snap(app, "desktop-floating")
        el(app, "nav.settings").tap(); sleep(2)
        snap(app, "desktop-over-settings")
        app.buttons["Done"].firstMatch.tap(); sleep(1)
        XCTAssertTrue(el(app, "desktop.floating").exists, "still open after a sheet")
        el(app, "desktop.layout.mini").tap(); sleep(2)
        XCTAssertTrue(el(app, "desktop.mini").waitForExistence(timeout: 4))
        snap(app, "desktop-mini")
        el(app, "preset.code").tap(); sleep(1)
        XCTAssertTrue(el(app, "desktop.mini").exists, "survives layout changes")
        el(app, "desktop.mini").tap(); sleep(1)
        el(app, "desktop.layout.full").tap(); sleep(2)
        snap(app, "desktop-full")
        el(app, "desktop.close").tap(); sleep(1)
        XCTAssertFalse(el(app, "desktop.display").exists)
    }

    /// Hardware keyboard: app shortcuts use ⌘-digits, ⇧⌘ and ⌃⌘ only.
    func testKeyboardShortcuts() {
        let app = launch()
        XCTAssertTrue(el(app, "workspace.project").waitForExistence(timeout: 10))
        app.typeKey("d", modifierFlags: [.control, .command]); sleep(2)
        XCTAssertTrue(el(app, "desktop.display").waitForExistence(timeout: 4), "⌃⌘D opens the desktop")
        app.typeKey("p", modifierFlags: [.control, .command]); sleep(1)
        XCTAssertTrue(el(app, "desktop.floating").waitForExistence(timeout: 4), "⌃⌘P floats it")
        app.typeKey("d", modifierFlags: [.control, .command]); sleep(1)
        XCTAssertFalse(el(app, "desktop.display").exists, "⌃⌘D closes it")
        app.typeKey("1", modifierFlags: [.control, .command]); sleep(1)
        XCTAssertTrue(el(app, "panel.editor").waitForExistence(timeout: 4), "⌃⌘1 = Code layout")
        app.typeKey("t", modifierFlags: .command); sleep(2)
        snap(app, "keyboard-new-terminal")
        app.typeKey("0", modifierFlags: .command); sleep(1)
        snap(app, "keyboard-navigator-toggled")
        app.typeKey("p", modifierFlags: .command); sleep(1)
        snap(app, "keyboard-quick-open")
    }

    func testMachinesAndSettingsSheets() {
        let app = launch()
        el(app, "nav.machines").tap()
        XCTAssertTrue(app.staticTexts["Musa Studios VPS"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Claude Code"].waitForExistence(timeout: 8))
        snap(app, "machines-sheet")
        app.buttons["Done"].firstMatch.tap(); sleep(1)
        el(app, "machine.switcher").tap(); sleep(1)
        snap(app, "account-menu")
    }

    /// First run for a new user: welcome → add a computer → SSH form.
    func testOnboardingAndAddComputer() {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance, project: nil, extra: ["-onboarding"])
            XCTAssertTrue(app.buttons["welcome.ssh"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["welcome.email"].exists)
            snap(app, "onboarding-\(appearance)-welcome")
            app.buttons["welcome.ssh"].tap()
            XCTAssertTrue(app.buttons["add.linux"].waitForExistence(timeout: 5))
            app.buttons["add.linux"].tap()
            XCTAssertTrue(app.textFields["ssh.host"].waitForExistence(timeout: 5))
            snap(app, "onboarding-\(appearance)-ssh")
            app.terminate()
        }
    }

    func testHostedWorkspaceOnboarding() {
        let app = launch(project: nil, extra: ["-onboarding"])
        XCTAssertTrue(app.buttons["welcome.hosted"].waitForExistence(timeout: 10))
        app.buttons["welcome.hosted"].tap()
        XCTAssertTrue(app.textFields["hosted.address"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["hosted.code"].exists)
        XCTAssertFalse(app.buttons["hosted.connect"].isEnabled)
        XCTAssertFalse(app.textFields["ssh.host"].exists)
        snap(app, "hafsa-hosted-onboarding")
    }
}
