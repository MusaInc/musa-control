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

/// The studio retypes the agent's real edits; replaying a script must land
/// exactly on the file as it is now.
final class StudioEditScriptTests: XCTestCase {
    func apply(_ s: EditScript) -> [String] {
        var doc = s.before
        for o in s.ops {
            let n = min(o.remove.count, doc.count - o.line)
            doc.replaceSubrange(o.line..<(o.line + n), with: o.insert)
        }
        return doc + s.tail
    }

    func testClaudeSingleLineEdit() throws {
        let current = "func a() {\n    let x = 2\n    print(x)\n}\n"
        let s = try XCTUnwrap(EditScripts.replacements([(old: "let x = 1", new: "let x = 2")], current: current))
        XCTAssertEqual(s.before[1], "    let x = 1")
        XCTAssertEqual(s.ops, [EditOp(line: 1, remove: ["    let x = 1"], insert: ["    let x = 2"])])
        XCTAssertEqual(apply(s), current.components(separatedBy: "\n"))
    }

    func testClaudeInsertionTrimsUnchangedLines() throws {
        let current = "func a() {\n    let x = 2\n    print(x)\n    print(\"done\")\n}\n"
        let s = try XCTUnwrap(EditScripts.replacements([(old: "print(x)\n}", new: "print(x)\n    print(\"done\")\n}")], current: current))
        XCTAssertEqual(s.ops, [EditOp(line: 3, remove: [], insert: ["    print(\"done\")"])])
        XCTAssertEqual(apply(s), current.components(separatedBy: "\n"))
    }

    func testClaudeEditOutsideProjectShowsSnippet() throws {
        let s = try XCTUnwrap(EditScripts.replacements([(old: "a\nb", new: "a\nc")], current: nil))
        XCTAssertEqual(s.before, ["a", "b"])
        XCTAssertEqual(apply(s), ["a", "c"])
    }

    func testCodexDiffReplaysToCurrentFile() throws {
        let current = "a\nb2\nc\nd\nnew\n"
        let diff = "@@ -1,4 +1,5 @@\n a\n-b\n+b2\n c\n d\n+new\n"
        let s = try XCTUnwrap(EditScripts.diff(diff, current: current))
        XCTAssertEqual(s.before, ["a", "b", "c", "d", ""])
        XCTAssertEqual(apply(s), current.components(separatedBy: "\n"))
    }

    func testCodexDiffWithoutFileUsesSnippet() throws {
        let s = try XCTUnwrap(EditScripts.diff("@@ -1,2 +1,2 @@\n keep\n-old\n+new\n", current: nil))
        XCTAssertEqual(s.before, ["keep", "old"])
        XCTAssertEqual(apply(s), ["keep", "new"])
    }

    func testNewFileTypesTopAndAppendsTail() {
        let text = (1...50).map { "line \($0)" }.joined(separator: "\n")
        let s = EditScripts.typing(text)
        XCTAssertEqual(s.ops.first?.insert.count, 32)
        XCTAssertEqual(apply(s), text.components(separatedBy: "\n"))
    }
}

// MARK: - Command Deck

final class DeckLayoutTests: XCTestCase {
    func assertTiles(_ rects: [CGRect], fill area: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        let total = rects.reduce(0) { $0 + $1.width * $1.height }
        XCTAssertEqual(total, area.width * area.height, accuracy: 1, "area conserved", file: file, line: line)
        for (i, a) in rects.enumerated() {
            XCTAssertTrue(area.insetBy(dx: -0.5, dy: -0.5).contains(a), "inside bounds", file: file, line: line)
            for b in rects[(i + 1)...] {
                let o = a.intersection(b)
                XCTAssertTrue(o.isNull || o.width * o.height < 1, "no overlap", file: file, line: line)
            }
        }
    }

    func testSquarifyConservesAreaWithoutOverlap() {
        let area = CGRect(x: 0, y: 0, width: 1100, height: 760)
        for weights in [[3.2, 1.3, 1.3, 1.0, 0.5, 0.5], [1.0], [2.0, 1.0], [1, 1, 1, 1, 1, 1, 1, 1, 1].map(Double.init)] {
            let r = DeckLayout.squarify(weights, in: area)
            XCTAssertEqual(r.count, weights.count)
            assertTiles(r, fill: area)
            // Proportional to weight.
            let total = weights.reduce(0, +)
            for (w, rect) in zip(weights, r) {
                XCTAssertEqual(rect.width * rect.height / (area.width * area.height), w / total, accuracy: 0.002)
            }
        }
    }

    func testSquarifyKeepsTilesNearSquare() {
        let r = DeckLayout.squarify([1, 1, 1, 1].map(Double.init), in: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        for t in r { XCTAssertLessThan(max(t.width / t.height, t.height / t.width), 2.01) }
    }

    func testApprovalTakesTheHeroSpotAndChipsSettleAtTheBottom() {
        let items = [
            DeckItem(id: "work", weight: 1.3, chip: false),
            DeckItem(id: "ask", weight: 3.2, chip: false),
            DeckItem(id: "idle", weight: 0.5, chip: false),
            DeckItem(id: "old", weight: 0.5, chip: true),
        ]
        let size = CGSize(width: 1100, height: 760)
        let p = DeckLayout.solve(items, in: size)
        let by = Dictionary(uniqueKeysWithValues: p.map { ($0.id, $0) })
        XCTAssertEqual(by["ask"]?.role, .hero)
        XCTAssertEqual(by["ask"]?.rect.origin, .zero, "most urgent sits top-left")
        XCTAssertEqual(by["old"]?.role, .chip)
        XCTAssertEqual(by["old"]!.rect.maxY, size.height, accuracy: 0.5)
        for t in p where t.role != .chip { XCTAssertLessThan(t.rect.maxY, by["old"]!.rect.minY, "tiles stay above the chips") }
        XCTAssertGreaterThan(by["work"]!.rect.width * by["work"]!.rect.height, by["idle"]!.rect.width * by["idle"]!.rect.height, "busier is bigger")
    }

    func testOverflowBecomesChipsAndTinyTilesGoCompact() {
        let items = (0..<12).map { DeckItem(id: "a\($0)", weight: 1, chip: false) }
        let p = DeckLayout.solve(items, in: CGSize(width: 700, height: 500))
        XCTAssertEqual(p.filter { $0.role != .chip }.count, DeckLayout.maxTiles)
        XCTAssertTrue(p.contains { $0.role == .chip })
        XCTAssertTrue(p.filter { $0.role != .chip }.allSatisfy { $0.role == .compact }, "nine tiles in 700×450 are compact")
    }

    func testLayoutIsStableForEqualWeights() {
        let items = [DeckItem(id: "b", weight: 1, chip: false), DeckItem(id: "a", weight: 1, chip: false)]
        let s = CGSize(width: 900, height: 600)
        XCTAssertEqual(DeckLayout.solve(items, in: s), DeckLayout.solve(items, in: s))
        XCTAssertEqual(DeckLayout.solve(items, in: s).first?.id, "b", "input order breaks ties")
    }
}

final class DeckPulseTests: XCTestCase {
    func ev(_ ts: Double, _ kind: String, _ detail: [String: JSONValue] = [:], title: String = "t") -> TimelineEvent {
        TimelineEvent(id: Int(ts), ts: ts, kind: kind, project: "p", session: "s", title: title, detail: .object(detail), notify: 0)
    }

    func testEditShowsTheLinesItWrote() {
        var p = AgentPulse()
        p.apply(ev(1, "agent.edit", ["path": .string("/x/a.swift"), "tool": .string("Edit"),
                                       "edits": .array([.object(["old": .string("let a = 1\n    return a"), "new": .string("let a = 2\n    return a")])])]))
        XCTAssertEqual(p.file, "/x/a.swift")
        XCTAssertEqual(p.verb, .editing)
        XCTAssertEqual(p.snippet, ["let a = 2"])
        XCTAssertEqual(p.added, 1)
        XCTAssertEqual(p.removed, 1)
    }

    func testDiffEditTakesFirstAddedRunWithoutCommonIndent() {
        var p = AgentPulse()
        p.apply(ev(1, "agent.edit", ["path": .string("/x/m.gd"), "change": .string("update"),
                                       "diff": .string("@@ -1,2 +1,3 @@\n func f():\n-\treturn 1\n+\tvar x := 2\n+\treturn x\n")]))
        XCTAssertEqual(p.snippet, ["var x := 2", "return x"])
        XCTAssertEqual(p.added, 2)
        XCTAssertEqual(p.removed, 1)
    }

    func testNothingInventedWhenTheEventHasNoText() {
        var p = AgentPulse()
        p.apply(ev(1, "agent.edit", ["path": .string("/x/new.swift"), "tool": .string("Write")]))
        XCTAssertEqual(p.verb, .writing)
        XCTAssertTrue(p.snippet.isEmpty)
        XCTAssertNil(p.term)
        XCTAssertNil(p.tests)
    }

    func testCommandsAndResults() {
        var p = AgentPulse()
        p.apply(ev(1, "agent.command", ["command": .string("npm test")]))
        XCTAssertEqual(p.term, "$ npm test")
        XCTAssertEqual(p.termKind, .command)
        p.apply(ev(2, "agent.command_failed", ["command": .string("npm test"), "output": .string("a\n\n3 passed, 1 failed\n"), "test": .bool(true)]))
        XCTAssertEqual(p.term, "3 passed, 1 failed")
        XCTAssertEqual(p.termKind, .fail)
        XCTAssertEqual(p.tests, "3 passed, 1 failed")
        XCTAssertEqual(p.testsOK, false)
        XCTAssertEqual(p.failTs, 2)
        // Codex reports the whole command at once, with its exit code.
        p.apply(ev(3, "agent.test", ["command": .string("npm test"), "exitCode": .number(0), "output": .string("4 passed")]))
        XCTAssertEqual(p.termKind, .ok)
        XCTAssertEqual(p.testsOK, true)
        XCTAssertEqual(p.okTs, 3)
    }

    func testLateEventsCountButDontOverwrite() {
        var p = AgentPulse()
        p.apply(ev(10, "agent.read", ["path": .string("/x/new.swift")]))
        p.apply(ev(5, "agent.read", ["path": .string("/x/old.swift")]))
        XCTAssertEqual(p.file, "/x/new.swift")
        XCTAssertEqual(p.events, 2)
        XCTAssertEqual(p.rate(now: 60), 2)
    }

    func testPlanProgress() {
        var p = AgentPulse()
        p.apply(ev(1, "agent.plan", ["items": .array([
            .object(["text": .string("a"), "status": .string("completed")]),
            .object(["text": .string("b"), "status": .string("in_progress")]),
            .object(["text": .string("c"), "status": .string("pending")])])]))
        XCTAssertEqual(p.planDone, 1)
        XCTAssertEqual(p.planTotal, 3)
        XCTAssertEqual(p.planCurrent, "b")
    }

    func testAuras() {
        let now = 1_000_000.0
        var p = AgentPulse()
        p.apply(ev(now - 5_000, "agent.read", ["path": .string("/a")]))
        XCTAssertEqual(AgentPulse.aura(status: "working", pulse: p, now: now), .working)
        XCTAssertEqual(AgentPulse.aura(status: "working", pulse: p, now: now + 60_000), .thinking, "quiet for a while: thinking")
        XCTAssertEqual(AgentPulse.aura(status: "approval", pulse: p, now: now), .approval)
        p.apply(ev(now - 1_000, "agent.command_failed", ["command": .string("make")]))
        XCTAssertEqual(AgentPulse.aura(status: "working", pulse: p, now: now), .failed)
        p.apply(ev(now, "agent.command_done", ["command": .string("make"), "ok": .bool(true)]))
        XCTAssertEqual(AgentPulse.aura(status: "working", pulse: p, now: now), .working, "a pass clears the failure")
        p.apply(ev(now + 1, "agent.done"))
        XCTAssertEqual(AgentPulse.aura(status: "idle", pulse: p, now: now + 2), .done)
        XCTAssertEqual(AgentPulse.aura(status: "idle", pulse: p, now: now + 3_600_000), .resting)
    }

    func agent(_ id: String, _ status: String, live: Bool = true, last: Double = 0) -> Agent {
        Agent(id: id, agent: "claude", agentName: "Claude Code", sessionId: nil, project: "p", projectInferred: nil, cwd: nil, title: id,
              lastPrompt: nil, lastMessage: nil, status: status, statusText: "", lastActivity: last, startedAt: nil, model: nil,
              pid: live ? 1 : nil, mode: nil, tmux: nil, managed: nil, controllable: true, approval: nil, counts: nil, lastEvent: nil)
    }

    func testEntriesOrderUrgentFirstAndSettleEndedAgents() {
        let now = 100_000_000_000.0
        var busy = AgentPulse()
        for i in 0..<12 { busy.apply(ev(now - Double(i) * 1000, "agent.read", ["path": .string("/a")])) }
        let es = DeckEntry.build(agents: [agent("idle", "idle"), agent("busy", "working"), agent("ask", "approval"),
                                          agent("gone", "ended", live: false, last: now - 60_000), agent("ancient", "ended", live: false, last: 0)],
                                 pulses: ["busy": busy], now: now)
        XCTAssertEqual(es.map(\.id), ["ask", "busy", "idle", "gone"], "ancient sessions are dropped")
        XCTAssertTrue(es.last!.chip)
        XCTAssertEqual(es[1].rate, 12)
        XCTAssertGreaterThan(es[1].weight, DeckEntry(agent: agent("q", "working"), pulse: AgentPulse(), aura: .working, rate: 0, chip: false).weight)
    }

    func testFixtureTimesAreRebasedToNow() throws {
        let json = #"{"ts": 1794085331848, "mtime": 1794007276402.0845, "id": 9001}"#
        let out = String(decoding: FixtureTransport.rebased(Data(json.utf8), now: 2_000_000_000_000), as: UTF8.self)
        XCTAssertTrue(out.contains(#""ts": 2000000000000"#), out)
        XCTAssertTrue(out.contains(#""mtime": 1999921944554.0845"#), out)
        XCTAssertTrue(out.contains(#""id": 9001"#))
    }
}

// MARK: - Studio 2.0

final class StudioWidgetTests: XCTestCase {
    func testJestOutputBecomesCasesWithSuitesAndFailures() {
        let out = """
        PASS src/onboarding/__tests__/linking.test.tsx
          ✓ links an account (41 ms)
          ✓ skips linking when offline (12 ms)
        FAIL src/onboarding/__tests__/fallback.test.tsx
          ✓ renders the fallback (18 ms)
          ✕ announces the step change (9 ms)

          ● Fallback › announces the step change

            expect(announce).toHaveBeenCalledWith("Step 2 of 4")
            Received: "Step 2"

        Tests:       1 failed, 3 passed, 4 total
        """
        let p = TestParser.parse(out)
        XCTAssertEqual(p.cases.map(\.result), [.pass, .pass, .pass, .fail])
        XCTAssertEqual(p.cases[0].name, "links an account")
        XCTAssertEqual(p.cases[0].ms, 41)
        XCTAssertEqual(p.cases[3].suite, "src/onboarding/__tests__/fallback.test.tsx")
        XCTAssertEqual(p.passed, 3)
        XCTAssertEqual(p.failed, 1)
        XCTAssertEqual(p.failures.count, 1)
        XCTAssertTrue(p.failures[0].hasPrefix("Fallback › announces the step change"))
        XCTAssertTrue(p.failures[0].contains("Received: \"Step 2\""))
    }

    func testOtherRunners() {
        XCTAssertEqual(TestParser.parse("ok 1 - adds\nnot ok 2 - subtracts\nok 3 - skip me # SKIP later\n").cases.map(\.result), [.pass, .fail, .skip])
        XCTAssertEqual(TestParser.parse("tests/test_a.py::test_one PASSED  [50%]\ntests/test_a.py::test_two FAILED [100%]").cases.map(\.result), [.pass, .fail])
        let go = TestParser.parse("=== RUN   TestA\n--- PASS: TestA (0.01s)\n--- FAIL: TestB (1.20s)\n")
        XCTAssertEqual(go.cases.map(\.name), ["TestA", "TestB"])
        XCTAssertEqual(go.cases[1].ms, 1200)
        XCTAssertEqual(TestParser.parse("test parse::works ... ok\ntest parse::breaks ... FAILED\ntest slow ... ignored").cases.map(\.result), [.pass, .fail, .skip])
        let xc = TestParser.parse("Test Case '-[AppTests.ParserTests testA]' passed (0.004 seconds).\nTest Case '-[AppTests.ParserTests testB]' failed (0.010 seconds).")
        XCTAssertEqual(xc.cases.map(\.name), ["testA", "testB"])
        XCTAssertEqual(xc.cases[0].suite, "AppTests.ParserTests")
    }

    func testCountsOnlyWhenThereAreNoPerTestLines() {
        let p = TestParser.parse("Sample output\ntest_camera.gd: 3 passed, 1 failed\n\n44 passed, 1 failed")
        XCTAssertTrue(p.cases.isEmpty)
        XCTAssertEqual(p.passed, 44, "totals come from the last summary line")
        XCTAssertEqual(p.failed, 1)
        var run = TestRun(id: 1, command: "x")
        run.passed = p.passed; run.failed = p.failed
        XCTAssertEqual(run.cellCount, 45)
        XCTAssertEqual(run.cell(0), .fail, "failures first so they're visible")
        XCTAssertEqual(run.cell(1), .pass)
        XCTAssertTrue(TestParser.parse("compiling...\ndone").cases.isEmpty)
        XCTAssertNil(TestParser.parse("compiling...\ndone").passed, "no invented counts")
    }

    func testCommandRunsOnlyTimeWhatWasTimed() {
        var r = CommandRun(id: 1, command: "make", start: 1_000, end: 4_000, exit: 0, ok: true, timed: true, test: false, build: true)
        XCTAssertEqual(r.duration, 3)
        r.timed = false
        XCTAssertNil(r.duration, "a single Codex event has no real duration")
        XCTAssertFalse(r.running)
        XCTAssertTrue(CommandRun.isBuild("xcodebuild -scheme App build"))
        XCTAssertTrue(CommandRun.isBuild("npm run build"))
        XCTAssertFalse(CommandRun.isBuild("rg -n make_thing src"))
        XCTAssertEqual(CommandRun.ring(10, longest: 10), 1, accuracy: 0.0001)
        XCTAssertLessThan(CommandRun.ring(1, longest: 100), 0.2)
    }

    func testDiffSplitAndHeat() {
        let s = EditScript(before: ["a", "b"], ops: [EditOp(line: 1, remove: ["b"], insert: ["B", "c"])])
        let d = DiffSplit.from(s, path: "/x/f.swift", id: 7)
        XCTAssertEqual(d.hunks.first?.before, ["b"])
        XCTAssertEqual(d.added, 2)
        XCTAssertEqual(d.removed, 1)
        let heat = ["/a": FileHeat(path: "/a", reads: 5, edits: 0, last: 1), "/b": FileHeat(path: "/b", reads: 0, edits: 2, last: 2)]
        XCTAssertEqual(HeatMap.top(heat).map(\.path), ["/b", "/a"], "an edit outweighs a read")
        XCTAssertEqual(HeatMap.recency(heat["/b"]!, newest: 2), 1)
    }
}

final class WindowBoardTests: XCTestCase {
    let wide = CGSize(width: 1200, height: 760)
    let phone = CGSize(width: 370, height: 520)

    func testFocusTakesThePrimarySlotAndOthersGlideAside() {
        var b = WindowBoard.initial
        var l = b.layout(in: wide)
        XCTAssertEqual(l.primary, .editor)
        XCTAssertEqual(l.tiled.count, 4)
        b.spawn(.terminal, focus: true)
        l = b.layout(in: wide)
        XCTAssertEqual(l.primary, .terminal)
        XCTAssertNotNil(l.frames[.editor], "the editor moves aside, it doesn't vanish")
        XCTAssertGreaterThan(l.frames[.terminal]!.width * l.frames[.terminal]!.height, l.frames[.editor]!.width * l.frames[.editor]!.height)
    }

    func testOverflowMinimisesIntoTheDock() {
        var b = WindowBoard.initial
        for k in [PaneKind.runs, .tests, .diff] { b.spawn(k, focus: false) }
        let l = b.layout(in: wide)
        XCTAssertEqual(l.tiled.count, WindowBoard.capacity(CGSize(width: wide.width, height: wide.height - WindowBoard.dockHeight - 8)))
        XCTAssertEqual(Set(l.tiled + l.docked), Set([.editor, .terminal, .thought, .explorer, .runs, .tests, .diff]))
        XCTAssertEqual(l.docked.first, l.docked.max { b.pane($0).touched < b.pane($1).touched }, "most recent first in the dock")
        let p = b.layout(in: phone)
        XCTAssertLessThanOrEqual(p.tiled.count, 2, "a phone shows one or two windows")
        XCTAssertEqual(p.primary, .editor)
    }

    func testPinnedWindowStaysPut() {
        var b = WindowBoard.initial
        let slot = b.slot(of: .editor, in: wide)
        XCTAssertEqual(slot, 0)
        b.togglePin(.editor, slot: slot)
        let before = b.layout(in: wide).frames[.editor]
        b.spawn(.tests, focus: true)
        b.spawn(.thought, focus: true)
        let after = b.layout(in: wide)
        XCTAssertEqual(after.tiled.first, .editor, "pinned to the primary slot")
        XCTAssertEqual(after.frames[.editor]?.origin, before?.origin, "same place (it only gives up room for the dock)")
        XCTAssertNotEqual(after.primary, .thought)
        XCTAssertNotNil(after.frames[.thought], "the new focus still gets a slot")
    }

    func testFloatingAndMinimise() {
        var b = WindowBoard.initial
        b.float(.terminal, frame: CGRect(x: 2000, y: -50, width: 400, height: 300))
        var l = b.layout(in: wide)
        XCTAssertEqual(l.floating, [.terminal])
        XCTAssertFalse(l.tiled.contains(.terminal))
        XCTAssertTrue(CGRect(origin: .zero, size: wide).contains(l.frames[.terminal]!), "kept on stage")
        b.dock(.terminal)
        b.minimize(.thought)
        l = b.layout(in: wide)
        XCTAssertTrue(l.tiled.contains(.terminal))
        XCTAssertEqual(l.docked, [.thought])
        b.bringForward(.thought)
        XCTAssertEqual(b.layout(in: wide).primary, .thought)
    }

    func testSlotsTileTheArea() {
        for n in 1...4 {
            for size in [wide, CGSize(width: 760, height: 900), phone] {
                let r = WindowBoard.slots(n, in: size)
                XCTAssertEqual(r.count, n)
                for s in r { XCTAssertTrue(CGRect(origin: .zero, size: size).insetBy(dx: -0.5, dy: -0.5).contains(s)) }
            }
        }
    }

    func ev(_ kind: String) -> TimelineEvent { TimelineEvent(id: 1, ts: 1, kind: kind, project: nil, session: "s", title: "", detail: nil, notify: 0) }

    func testEventsMapToWindows() {
        XCTAssertEqual(WindowRules.route(ev("agent.read"), testResult: false).focus, .editor)
        XCTAssertEqual(WindowRules.route(ev("agent.edit"), testResult: false).also, [.diff, .files])
        XCTAssertEqual(WindowRules.route(ev("agent.command"), testResult: false).focus, .terminal)
        XCTAssertEqual(WindowRules.route(ev("agent.test"), testResult: true).focus, .tests)
        XCTAssertEqual(WindowRules.route(ev("agent.command_failed"), testResult: false).focus, .terminal)
        XCTAssertEqual(WindowRules.route(ev("agent.image"), testResult: false).focus, .lightbox)
        XCTAssertEqual(WindowRules.route(ev("agent.message"), testResult: false).focus, .thought)
        XCTAssertNil(WindowRules.route(ev("agent.plan"), testResult: false).focus, "plan updates don't steal focus")
    }
}

final class StageCameraTests: XCTestCase {
    let stage = CGSize(width: 1100, height: 700)

    func testNoFocusNoMove() {
        XCTAssertEqual(StageCamera.shot(stage: stage, focus: nil), StageCamera.Shot())
        XCTAssertEqual(StageCamera.shot(stage: stage, focus: CGRect(origin: .zero, size: stage)).scale, 1, accuracy: 0.0001, "a full-stage window doesn't zoom")
    }

    func testLeansTowardTheActionButNeverShowsTheEdge() {
        for f in [CGRect(x: 0, y: 0, width: 300, height: 200), CGRect(x: 800, y: 500, width: 300, height: 200),
                  CGRect(x: 400, y: 250, width: 300, height: 200), CGRect(x: 0, y: 0, width: 680, height: 700)] {
            let s = StageCamera.shot(stage: stage, focus: f)
            XCTAssertLessThanOrEqual(s.scale, 1.06 + 0.0001, "gentle")
            XCTAssertGreaterThanOrEqual(s.scale, 1)
            let c = StageCamera.covered(s, stage: stage)
            XCTAssertTrue(c.insetBy(dx: -0.01, dy: -0.01).contains(CGRect(origin: .zero, size: stage)), "viewport stays covered for \(f)")
        }
        let topLeft = StageCamera.shot(stage: stage, focus: CGRect(x: 0, y: 0, width: 300, height: 200))
        XCTAssertGreaterThan(topLeft.offset.width, 0, "pans toward a top-left window")
        XCTAssertGreaterThan(topLeft.offset.height, 0)
    }
}

final class ScrubberTests: XCTestCase {
    func ev(_ i: Int, _ kind: String, _ detail: [String: JSONValue] = [:]) -> TimelineEvent {
        TimelineEvent(id: i, ts: Double(i) * 1000, kind: kind, project: nil, session: "s", title: "\(kind) \(i)", detail: .object(detail), notify: 0)
    }

    func testMarksClassifyRealOutcomes() {
        let h = [ev(0, "agent.prompt"), ev(1, "agent.read"), ev(2, "agent.edit"), ev(3, "agent.command"),
                 ev(4, "agent.command_failed"), ev(5, "agent.test", ["exitCode": .number(1), "output": .string("1 failed")]),
                 ev(6, "agent.test", ["exitCode": .number(0), "output": .string("3 passed")]), ev(7, "agent.done")]
        XCTAssertEqual(Scrub.marks(h).map(\.kind), [.prompt, .read, .edit, .command, .failure, .failure, .test, .done])
        XCTAssertEqual(Scrub.marks(h).map(\.id), Array(0..<8), "ids are history indices")
    }

    func testJumpsBetweenEditsCommandsAndFailures() {
        let m = Scrub.marks([ev(0, "agent.message"), ev(1, "agent.edit"), ev(2, "agent.read"), ev(3, "agent.command_failed"), ev(4, "agent.message")])
        let target: (ScrubMark.Kind) -> Bool = { [.edit, .command, .test, .failure].contains($0) }
        XCTAssertEqual(Scrub.next(m, after: 0, target), 1)
        XCTAssertEqual(Scrub.next(m, after: 1, target), 3)
        XCTAssertNil(Scrub.next(m, after: 3, target))
        XCTAssertEqual(Scrub.previous(m, before: 5, target), 3)
        XCTAssertEqual(Scrub.previous(m, before: 3, { $0 == .failure }), nil)
    }

    func testTrackMapping() {
        XCTAssertEqual(Scrub.index(at: 0, width: 200, count: 11), 0)
        XCTAssertEqual(Scrub.index(at: 200, width: 200, count: 11), 10)
        XCTAssertEqual(Scrub.index(at: 99, width: 200, count: 11), 5)
        XCTAssertEqual(Scrub.index(at: -40, width: 200, count: 11), 0, "clamped")
        XCTAssertEqual(Scrub.x(of: 5, width: 200, count: 11), 100)
        XCTAssertEqual(Scrub.nextRate(1), 2)
        XCTAssertEqual(Scrub.nextRate(8), 1, "8× wraps to 1×")
    }
}

/// Multi-machine support: models, migration, scoping and the account nonce.
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

    func testNineShortcutsAtMost() {
        XCTAssertEqual(AppSection.allCases.compactMap(\.shortcut).count, min(9, AppSection.allCases.count))
    }
}

final class LiveWorkspaceTests: XCTestCase {
    func event(_ id: Int, _ kind: String, _ detail: [String: JSONValue] = [:], session: String = "live-test") -> TimelineEvent {
        TimelineEvent(id: id, ts: Double(id), kind: kind, project: nil, session: session, title: kind, detail: .object(detail), notify: 0)
    }

    @MainActor
    func testNarrationArrivesImmediatelyAndSurvivesOtherActivity() {
        let client = GatewayClient(base: URL(string: "https://example.invalid")!, token: nil, transport: FixtureTransport())
        let d = StudioDirector(agentId: "live-test", client: client)
        d.mode = .live
        let text = String(repeating: "A complete progress update. ", count: 50)
        d.ingest([event(1, "agent.message", ["text": .string(text)])])
        XCTAssertEqual(d.narration, text.trimmingCharacters(in: .whitespacesAndNewlines))
        d.ingest([event(2, "agent.command", ["command": .string("npm test")])])
        XCTAssertEqual(d.narration, text.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(d.currentEvent?.kind, "agent.command")
        d.ingest([event(3, "agent.message", ["text": .string("Other session")], session: "another")])
        XCTAssertEqual(d.currentEvent?.kind, "agent.command")
        d.stop()
    }

    func testLongCommandsAndNotesAreNotShortened() {
        let command = "node " + String(repeating: "long_argument ", count: 80)
        XCTAssertEqual(StudioDirector.oneLine(command, 20), command)
        let note = String(repeating: "Keep the entire sentence. ", count: 80)
        XCTAssertEqual(StudioDirector.plainText(note, 20), note.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @MainActor
    func testSearchUsesTheActualQueryAndActionsStayConcise() {
        let d = StudioDirector(agentId: "live-test", client: GatewayClient(base: URL(string: "https://example.invalid")!, token: nil, transport: FixtureTransport()))
        d.currentEvent = event(1, "agent.tool", ["tool": .string("Grep"), "input": .string("{\"pattern\":\"touch controls\"}")])
        let view = StudioLiveView(d: d, agent: nil)
        XCTAssertEqual(view.searchQuery, "touch controls")
        d.currentEvent = event(2, "agent.edit", ["path": .string("/a/very/long/path/file.gd")])
        XCTAssertEqual(view.action, "Editing a file")
    }
}
