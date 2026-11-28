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
        var l = WorkspaceLayout.standard(portrait: false)
        l.columns[1].panels.removeAll()
        l.normalise()
        XCTAssertEqual(l.columns.count, 1)
        XCTAssertEqual(l.columns.reduce(0) { $0 + $1.width }, 1, accuracy: 0.0001)
        for c in l.columns { XCTAssertEqual(c.heights.reduce(0, +), 1, accuracy: 0.0001) }
    }
    func testLayoutRoundTripsPerProject() {
        var l = WorkspaceLayout.standard(portrait: false)
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

    func testFeedGroupsConsecutiveImagesAndKeepsDesktopAndBuildsStandalone() {
        let feed = Feed.build([
            ev(1, "agent.image", "Render 1", ["path": .string("/tmp/a.png")]),
            ev(2, "agent.image", "Render 2", ["path": .string("/tmp/b.png")]),
            ev(3, "agent.command", "$ blender -b scene.blend", ["follow": .object(["view": .string("vnc"), "app": .string("blender")])]),
            ev(4, "build.started", "Building app", ["build": .string("b1")]),
            ev(5, "visual.output", "chart.png", ["path": .string("chart.png"), "kind": .string("image")]),
        ])
        XCTAssertEqual(feed.count, 4)
        if case .images(let imgs) = feed[0] { XCTAssertEqual(imgs.count, 2) } else { XCTFail("consecutive images group into gallery") }
        if case .single(let d) = feed[1] { XCTAssertTrue(Feed.isDesktop(d)) } else { XCTFail("desktop events stay standalone") }
        if case .single(let b) = feed[2] { XCTAssertTrue(Feed.isBuild(b)) } else { XCTFail("build events stay standalone") }
        if case .single(let v) = feed[3] { XCTAssertEqual(v.kind, "visual.output") } else { XCTFail("visual artifacts stay standalone") }
    }

    func testNavigationIncludesStudioToolsAfterExistingSections() {
        XCTAssertEqual(AppSection.allCases, [.agents, .terminal, .files, .settings, .automation])
    }
}

final class FixtureTests: XCTestCase {
    func testFixtureTimesAreRebasedToNow() throws {
        let json = #"{"ts": 1794085331848, "mtime": 1794007276402.0845, "id": 9001}"#
        let out = String(decoding: FixtureTransport.rebased(Data(json.utf8), now: 2_000_000_000_000), as: UTF8.self)
        XCTAssertTrue(out.contains(#""ts": 2000000000000"#), out)
        XCTAssertTrue(out.contains(#""mtime": 1999921944554.0845"#), out)
        XCTAssertTrue(out.contains(#""id": 9001"#))
    }
}

@MainActor
final class WorkspaceStoreTests: XCTestCase {
    func store() -> WorkspaceStore {
        let ws = WorkspaceStore()
        ws.open(project: "unit-\(UUID().uuidString.prefix(6))")
        ws.apply(.code)
        return ws
    }

    func testRevealReusesAPanelOfThatKind() {
        let ws = store()
        let n = ws.layout.slots.count
        let id = ws.reveal(.terminal, config: ["tmux": "mc-claude-x"]) { $0.config["tmux"] == "mc-claude-x" }
        XCTAssertEqual(ws.layout.slots.count, n + 1, "no terminal showed that session yet")
        let again = ws.reveal(.terminal, config: ["tmux": "mc-claude-x"]) { $0.config["tmux"] == "mc-claude-x" }
        XCTAssertEqual(again, id)
        XCTAssertEqual(ws.layout.slots.count, n + 1)
        XCTAssertEqual(ws.focused, id)
    }

    func testRevealWithoutMatchReusesTheFirstOfItsKind() {
        let ws = store()
        let editor = ws.layout.slots.first { $0.kind == .editor }!.id
        XCTAssertEqual(ws.reveal(.editor), editor)
    }

    func testMinimiseAndRestore() {
        let ws = store()
        let t = ws.layout.slots.first { $0.kind == .terminal }!
        ws.minimize(t.id)
        XCTAssertFalse(ws.layout.slots.contains { $0.id == t.id })
        XCTAssertEqual(ws.layout.minimized.map(\.kind), [.terminal])
        ws.restore(t.id)
        XCTAssertTrue(ws.layout.slots.contains { $0.kind == .terminal })
        XCTAssertTrue(ws.layout.minimized.isEmpty)
    }

    func testDropMovesAPanelBesideAnother() {
        let ws = store()
        let agent = ws.layout.slots.first { $0.kind == .agent }!.id
        let editor = ws.layout.slots.first { $0.kind == .editor }!.id
        let before = ws.layout.columns.count
        ws.drop(agent, on: editor, .left)
        XCTAssertEqual(ws.layout.columns.count, before, "the agent's old column emptied and a new one appeared")
        XCTAssertEqual(ws.layout.columns.first?.panels.first?.id, agent)
        XCTAssertEqual(ws.layout.columns.reduce(0) { $0 + $1.width }, 1, accuracy: 0.0001)
        ws.drop(agent, on: editor, .below)
        let loc = ws.layout.locate(agent)!, el = ws.layout.locate(editor)!
        XCTAssertEqual(loc.0, el.0); XCTAssertEqual(loc.1, el.1 + 1)
    }

    func testLayoutsAreSavedPerProjectAndOrientation() {
        let ws = WorkspaceStore()
        let p = "unit-\(UUID().uuidString.prefix(6))"
        ws.open(project: p)
        ws.apply(.visual)
        let landscape = ws.layout
        ws.setPortrait(true)
        XCTAssertNotEqual(ws.layout.slots.map(\.id), landscape.slots.map(\.id))
        ws.setPortrait(false)
        XCTAssertEqual(ws.layout.slots.map(\.id), landscape.slots.map(\.id))
    }
}

final class VisualiserTests: XCTestCase {
    func testListDecodesAndModelsUseTheViewer() throws {
        let json = #"{"project":"p","dir":"/d","items":[{"path":"runs/1/figure-1.png","name":"figure-1.png","kind":"image","size":10,"mtime":5,"run":"1","linked":false},{"path":"m.glb","name":"m.glb","kind":"model","size":1,"mtime":4,"run":null,"linked":true}]}"#
        let l = try JSONDecoder().decode(VisualList.self, from: Data(json.utf8))
        XCTAssertEqual(l.items.count, 2)
        let model = VisualScheme.url(for: l.items[1], project: "p")
        XCTAssertEqual(model.scheme, "mcvisual")
        XCTAssertTrue(model.absoluteString.contains("/viewer/model.html?ext=glb"), model.absoluteString)
        let image = VisualScheme.url(for: l.items[0], project: "p")
        XCTAssertTrue(image.absoluteString.hasPrefix("mcvisual://x/image?src="))
    }
}

final class MachineTests: XCTestCase {
    override func setUp() {
        for k in ["machines.v1", "machines.active", "machines.migrated", "serverURL"] { UserDefaults.standard.removeObject(forKey: k) }
    }

    func testNewGatewayFieldsDecodeAndOldOnesStillDo() throws {
        let old = #"{"id":"a","name":"iPad","expiresAt":1,"server":{"version":"0.1.0","host":"musastudios.co.uk"}}"#
        let me = try JSONDecoder().decode(Me.self, from: Data(old.utf8))
        XCTAssertNil(me.capabilities)
        XCTAssertEqual(me.server?.host, "musastudios.co.uk")
        let new = #"{"id":"a","name":"iPad","expiresAt":1,"via":"relay","server":{"profile":"companion","name":"box"},"capabilities":{"terminal":true,"relay":"online"}}"#
        let m2 = try JSONDecoder().decode(Me.self, from: Data(new.utf8))
        XCTAssertEqual(m2.via, "relay"); XCTAssertEqual(m2.capabilities?.terminal, true)
        let providers = try JSONDecoder().decode([ProviderInfo].self, from: FixtureTransport.fixture("providers")!)
        XCTAssertEqual(providers.map(\.id), ["claude", "codex", "gemini"])
        XCTAssertEqual(providers[0].npmPackage, "@anthropic-ai/claude-code")
        let ws = try JSONDecoder().decode(WebSession.self, from: Data(#"{"cookie":{"name":"mc_web","value":"v","path":"/","maxAge":10,"secure":false},"base":"http://127.0.0.1:5"}"#.utf8))
        XCTAssertEqual(ws.cookie.secure, false)
    }

    func testLegacyPairingBecomesThePersonalMachineWithoutRepairing() {
        UserDefaults.standard.set("https://example.org/control", forKey: "serverURL")
        MachineStore.migrateIfNeeded(readLegacyToken: { "mc_legacy" })
        let m = MachineStore.active
        XCTAssertEqual(m?.id, Machine.personalId)
        XCTAssertEqual(m?.url, "https://example.org/control")
        XCTAssertEqual(m?.tokenKey, "deviceToken", "keeps the original Keychain item, without copying the secret")
        XCTAssertEqual(MachineStore.scoped("terminalTabs", Machine.personalId), "terminalTabs")
        XCTAssertEqual(MachineStore.scoped("terminalTabs", "ssh-1"), "terminalTabs.ssh-1")
        MachineStore.migrateIfNeeded(readLegacyToken: { XCTFail("migration already completed"); return nil })
        XCTAssertEqual(MachineStore.all.count, 1, "runs once")
    }

    func testMigrationRetriesWhenKeychainIsTemporarilyUnavailable() {
        MachineStore.migrateIfNeeded(readLegacyToken: { nil })
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "machines.migrated"))
        MachineStore.migrateIfNeeded(readLegacyToken: { "mc_legacy" })
        XCTAssertEqual(MachineStore.active?.id, Machine.personalId)
    }

    func testMachinesKeepTheirOwnTokensAndSSHSettings() {
        let a = Machine(id: "ssh-a", name: "A", kind: .ssh, host: "a.example", port: 2222, user: "dev", pins: ["SHA256:x"], remotePort: 8171, platform: "linux", addedAt: 0)
        let b = Machine(id: "relay-b", name: "B", kind: .relay, cloudId: "b-cloud", platform: "darwin", addedAt: 0)
        Keychain.setString("mc_a", for: a.tokenKey)
        MachineStore.upsert(a); MachineStore.upsert(b)
        MachineStore.activeId = a.id
        XCTAssertEqual(SSHSettings.stored?.host, "a.example")
        XCTAssertEqual(SSHSettings.stored?.port, 2222)
        MachineStore.activeId = b.id
        XCTAssertNil(SSHSettings.stored, "relay machines have no SSH; terminals use the relay socket")
        XCTAssertEqual(b.symbol, "laptopcomputer")
        XCTAssertTrue(CloudAuth.machineBase("b-cloud").absoluteString.hasSuffix("/m/b-cloud"))
        MachineStore.remove(a.id)
        XCTAssertNil(Keychain.string("machine.ssh-a.token"), "removing a machine deletes its token")
        MachineStore.remove(b.id)
    }

    func testAppleNonceIsHashedForApple() {
        let raw = Account.randomNonce()
        XCTAssertGreaterThan(raw.count, 20)
        XCTAssertEqual(Account.sha256("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

}
