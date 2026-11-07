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
}
