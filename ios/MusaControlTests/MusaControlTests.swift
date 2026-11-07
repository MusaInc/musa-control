import XCTest
import CryptoKit
@testable import MusaControl

final class ModelDecodingTests: XCTestCase {
    /// Every fixture was captured from the real gateway; the app's models must decode all of them.
    func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: AppModel.self).url(forResource: name, withExtension: "json", subdirectory: "Fixtures"), "missing fixture \(name)")
        return try Data(contentsOf: url)
    }
    func decode<T: Decodable>(_ t: T.Type, _ name: String) throws -> T { try JSONDecoder().decode(T.self, from: fixture(name)) }

    func testGatewayResponsesDecode() throws {
        let o = try decode(Overview.self, "overview")
        XCTAssertFalse(o.system.services.isEmpty)
        XCTAssertFalse(try decode([Project].self, "projects").isEmpty)
        let agents = try decode([Agent].self, "agents")
        XCTAssertFalse(agents.isEmpty)
        _ = try decode([TimelineEvent].self, "agent-timeline")
        _ = try decode([TimelineEvent].self, "timeline")
        _ = try decode(ScreenCapture.self, "agent-screen")
        let d = try decode(ProjectDetail.self, "project-detail")
        XCTAssertFalse(d.commands.isEmpty)
        _ = try decode(DirListing.self, "files")
        _ = try decode(FileContent.self, "file")
        _ = try decode(GitStatus.self, "git-status")
        _ = try decode([Commit].self, "git-log")
        _ = try decode([Branch].self, "git-branches")
        _ = try decode(DiffResponse.self, "git-diff")
        _ = try decode([Revision].self, "revisions")
        _ = try decode(PreviewsResponse.self, "previews")
        _ = try decode([Screenshot].self, "screenshots")
        _ = try decode([Display].self, "displays")
        _ = try decode(TmuxList.self, "tmux")
        _ = try decode([DeviceRow].self, "devices")
        _ = try decode([WorkflowRun].self, "runs")
        _ = try decode(Me.self, "me")
    }
}

final class ParserTests: XCTestCase {
    func testSSEParserDispatchesEvents() {
        var p = SSEParser()
        XCTAssertNil(p.feed(line: "id: 42"))
        XCTAssertNil(p.feed(line: "event: agent.edit"))
        XCTAssertNil(p.feed(line: "data: {\"a\":1}"))
        let m = p.feed(line: "")
        XCTAssertEqual(m, SSEParser.Message(id: "42", event: "agent.edit", data: "{\"a\":1}"))
        XCTAssertNil(p.feed(line: ": ping"))
        XCTAssertNil(p.feed(line: ""))
    }

    func testDiffParserNumbersLines() {
        let diff = """
        diff --git a/src/app.js b/src/app.js
        --- a/src/app.js
        +++ b/src/app.js
        @@ -1,3 +1,3 @@
         one
        -two
        +TWO
         three
        """
        let files = DiffParser.parse(diff)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].path, "src/app.js")
        XCTAssertEqual(files[0].added, 1)
        XCTAssertEqual(files[0].removed, 1)
        let added = files[0].lines.first { $0.kind == .added }
        XCTAssertEqual(added?.newNo, 2)
        XCTAssertEqual(files[0].lines.first { $0.kind == .removed }?.oldNo, 2)
    }

    func testHighlighterHandlesAllLanguages() {
        let font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        for p in ["a.swift", "a.gd", "a.py", "a.json", "a.html", "a.css", "a.sh", "a.md", "a.ts"] {
            let s = SyntaxHighlighter.highlight("let x = \"str\" // comment\n# hash\n/* block */ 42", path: p, font: font)
            XCTAssertGreaterThan(s.length, 0)
        }
    }
}

final class SSHKeyTests: XCTestCase {
    // Vector generated with ssh-keygen -t ed25519 on the VPS.
    let pub = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDmGv2lWwJ49Ematqv9+TlVJj7gX8zd0S/FwAJHKK8l/ vector"
    let fp = "SHA256:ia+hXQvEDUEYmL88G/SF3yoIA9j+w8BosPcSLavKk9s"

    func testFingerprintMatchesSSHKeygen() { XCTAssertEqual(SSHKeys.fingerprint(openSSH: pub), fp) }

    func testPublicBlobMatchesOpenSSHWireFormat() throws {
        let blob = try XCTUnwrap(Data(base64Encoded: String(pub.split(separator: " ")[1])))
        let raw = blob.suffix(32)
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: raw)
        XCTAssertEqual(SSHKeys.publicBlob(key), blob)
    }
}

final class LayoutTests: XCTestCase {
    func testNormaliseKeepsFractionsValid() {
        var l = WorkspaceLayout.standard()
        l.columns[1].panels.removeAll()
        l.normalise()
        XCTAssertEqual(l.columns.count, 2)
        XCTAssertEqual(l.columns.reduce(0) { $0 + $1.width }, 1, accuracy: 0.0001)
        for c in l.columns { XCTAssertEqual(c.heights.reduce(0, +), 1, accuracy: 0.0001) }
    }
    func testLayoutRoundTripsPerProject() {
        var l = WorkspaceLayout.standard()
        l.maximized = l.columns[0].panels[0].id
        WorkspaceLayoutStore.save(l, "unit-test-project", portrait: false)
        XCTAssertEqual(WorkspaceLayoutStore.load("unit-test-project", portrait: false), l)
        XCTAssertNotEqual(WorkspaceLayoutStore.load("another-project", portrait: false), l)
    }

    // MARK: Content-first activity feed

    private func ev(_ id: Int, _ kind: String, _ title: String = "t", _ detail: [String: JSONValue] = [:]) -> TimelineEvent {
        TimelineEvent(id: id, ts: Double(id) * 1000, kind: kind, project: "p", session: "s", title: title, detail: .object(detail), notify: 0)
    }

    func testFeedFoldsRoutineStepsAndKeepsResultsSeparate() {
        let feed = Feed.build([
            ev(1, "agent.prompt", "Do it", ["text": .string("Do it")]),
            ev(2, "agent.command", "$ ls"), ev(3, "agent.command", "$ rg x"), ev(4, "agent.read", "Reading a.swift"),
            ev(5, "agent.edit", "Edited a.swift", ["path": .string("/x/a.swift")]), ev(6, "agent.edit", "Edited b.swift", ["path": .string("/x/b.swift")]),
            ev(7, "agent.command_failed", "Failed (1): make", ["exitCode": .number(1)]),
            ev(8, "agent.test", "Running tests: npm test", ["exitCode": .number(0), "output": .string("12 passed")]),
            ev(9, "agent.message", "Done"),
        ])
        XCTAssertEqual(feed.count, 6)
        if case .steps(let s) = feed[1] { XCTAssertEqual(s.count, 3) } else { XCTFail("routine commands fold into one row") }
        if case .edits(let e) = feed[2] { XCTAssertEqual(e.count, 2) } else { XCTFail("consecutive edits group") }
        if case .single(let f) = feed[3] { XCTAssertEqual(f.kind, "agent.command_failed") } else { XCTFail("failures stand alone") }
        if case .single(let t) = feed[4] { XCTAssertTrue(Feed.isTestResult(t)) } else { XCTFail("test results stand alone") }
    }

    func testAppInstructionAndTranscriptPromptAreOneMessage() {
        let feed = Feed.build([
            ev(1, "agent.instruction", "You: Fix the build", ["text": .string("Fix the build")]),
            ev(2, "agent.prompt", "Fix the build", ["text": .string("Fix the build")]),
        ])
        XCTAssertEqual(feed.count, 1)
    }

    func testMessageSegmentsSplitFencedCode() {
        let segs = MessageText.segments("Intro\n```swift\nlet a = 1\n```\nOutro")
        XCTAssertEqual(segs.count, 3)
        if case .code(let lang, let code) = segs[1] { XCTAssertEqual(lang, "swift"); XCTAssertEqual(code, "let a = 1") } else { XCTFail("code block") }
    }

    func testTestSummaryQuotesOnlyRealOutput() {
        XCTAssertEqual(Feed.testSummary("noise\n44 passed, 1 failed"), "44 passed, 1 failed")
        XCTAssertNil(Feed.testSummary("compiling...\ndone"), "no invented counts")
    }
}
