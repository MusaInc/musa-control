import Foundation

// Data behind the studio's purpose-built widgets. All of it is parsed from
// what the agent's events actually carry; when an event doesn't carry
// something (a per-test breakdown, a command's duration), the widget shows
// less rather than making it up.

// MARK: - Tests

struct TestCase: Identifiable, Equatable {
    enum Result: Equatable { case pass, fail, skip }
    let id: Int
    let name: String
    let suite: String?
    let result: Result
    let ms: Double?
}

struct TestRun: Identifiable, Equatable {
    let id: Int
    let command: String
    var running = true
    var ok: Bool?
    var cases: [TestCase] = []
    var passed: Int?
    var failed: Int?
    var skipped: Int?
    var failures: [String] = []   // failure messages quoted from the output
    var summary: String?
    var revealed = 0              // cells shown so far (fills in as output streams)

    /// Cells for the matrix: one per parsed test, or (when the runner only
    /// printed totals) one per counted result, with no names.
    var cellCount: Int { cases.isEmpty ? (passed ?? 0) + (failed ?? 0) + (skipped ?? 0) : cases.count }
    func cell(_ i: Int) -> TestCase.Result {
        if !cases.isEmpty { return cases[i].result }
        let p = passed ?? 0, f = failed ?? 0
        // Count-only: failures first so they're visible in a big run.
        return i < f ? .fail : i < f + p ? .pass : .skip
    }
}

enum TestParser {
    struct Parsed: Equatable {
        var cases: [TestCase] = []
        var passed: Int?
        var failed: Int?
        var skipped: Int?
        var failures: [String] = []
    }

    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    private static let suiteRe = re(#"^(PASS|FAIL)\s+(\S+)"#)
    private static let checkRe = re(#"^(✓|✔|√|✕|✗|×|✘|○)\s+(.+?)(?:\s+\((\d+(?:\.\d+)?)\s*(ms|s)\))?$"#)
    private static let tapRe = re(#"^(ok|not ok)\s+\d+\s*-?\s*(.+?)(\s+#\s*(SKIP|skip|TODO).*)?$"#)
    private static let pytestRe = re(#"^(\S+::\S+)\s+(PASSED|FAILED|SKIPPED|ERROR|XFAIL|XPASS)"#)
    private static let goRe = re(#"^\s*--- (PASS|FAIL|SKIP): (\S+)(?: \((\d+(?:\.\d+)?)s\))?"#)
    private static let cargoRe = re(#"^test (\S+) \.\.\. (ok|FAILED|ignored)"#)
    private static let xcRe = re(#"Test Case '-\[(\S+) (\S+)\]' (passed|failed|skipped) \((\d+(?:\.\d+)?) seconds\)"#)
    private static let swiftTestingRe = re(#"^(✔|✘|􀢄|􁁛)\s+Test (\S+?)(?:\(\))? (passed|failed)"#)
    private static let mochaFailRe = re(#"^\d+\)\s+(.+)$"#)
    private static let countRe = re(#"(\d+)\s+(passed|passing|failed|failing|skipped|pending|ignored)\b"#)

    private static func groups(_ r: NSRegularExpression, _ s: String) -> [String?]? {
        let ns = s as NSString
        guard let m = r.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? nil : ns.substring(with: m.range(at: $0)) }
    }

    static func parse(_ output: String) -> Parsed {
        var out = Parsed()
        var suite: String?
        var id = 0
        func add(_ name: String, _ r: TestCase.Result, _ ms: Double? = nil) {
            id += 1
            out.cases.append(TestCase(id: id, name: name.trimmingCharacters(in: .whitespaces), suite: suite, result: r, ms: ms))
        }
        let lines = output.components(separatedBy: "\n").map { StudioDirector.stripAnsi($0) }
        var i = 0
        while i < lines.count {
            let raw = lines[i]
            let l = raw.trimmingCharacters(in: .whitespaces)
            i += 1
            if l.isEmpty { continue }
            if let g = groups(suiteRe, l) { suite = g[2]; continue }
            if let g = groups(swiftTestingRe, l), let name = g[2] { add(name, g[3] == "passed" ? .pass : .fail); continue }
            if let g = groups(checkRe, l), let mark = g[1], let name = g[2] {
                let secs = g[4] == "s"
                let ms: Double? = g[3].flatMap { Double($0) }.map { secs ? $0 * 1000 : $0 }
                let r: TestCase.Result = "✓✔√".contains(mark) ? .pass : mark == "○" ? .skip : .fail
                add(name, r, ms)
                continue
            }
            if let g = groups(tapRe, l), let name = g[2], !name.hasPrefix("#") {
                add(name, g[4] != nil ? .skip : g[1] == "ok" ? .pass : .fail)
                continue
            }
            if let g = groups(pytestRe, l), let name = g[1] {
                add(name, ["PASSED", "XFAIL", "XPASS"].contains(g[2] ?? "") ? .pass : g[2] == "SKIPPED" ? .skip : .fail)
                continue
            }
            if let g = groups(goRe, l), let name = g[2] {
                let r: TestCase.Result = g[1] == "PASS" ? .pass : g[1] == "SKIP" ? .skip : .fail
                let ms: Double? = g[3].flatMap { Double($0) }.map { $0 * 1000 }
                add(name, r, ms)
                continue
            }
            if let g = groups(cargoRe, l), let name = g[1] { add(name, g[2] == "ok" ? .pass : g[2] == "ignored" ? .skip : .fail); continue }
            if let g = groups(xcRe, l), let cls = g[1], let name = g[2] {
                let prev = suite; suite = cls
                let r: TestCase.Result = g[3] == "passed" ? .pass : g[3] == "skipped" ? .skip : .fail
                let ms: Double? = g[4].flatMap { Double($0) }.map { $0 * 1000 }
                add(name, r, ms)
                suite = prev
                continue
            }
            // Failure details: Jest "● Suite › test" plus the lines under it.
            if l.hasPrefix("●") {
                var msg = String(l.dropFirst()).trimmingCharacters(in: .whitespaces)
                var extra = 0
                while i < lines.count, extra < 2 {
                    let n = lines[i].trimmingCharacters(in: .whitespaces)
                    if n.hasPrefix("●") || n.hasPrefix("Tests:") { break }
                    if !n.isEmpty { msg += "\n" + n; extra += 1 }
                    i += 1
                }
                out.failures.append(msg)
                continue
            }
            if l.hasPrefix("FAILED ") || l.hasPrefix("E   ") { out.failures.append(l); continue }
        }
        // Totals, from the last line that states them (the runner's own summary).
        for l in lines.reversed() {
            let ns = l as NSString
            let ms = countRe.matches(in: l, range: NSRange(location: 0, length: ns.length))
            guard !ms.isEmpty else { continue }
            for m in ms {
                let n = Int(ns.substring(with: m.range(at: 1))) ?? 0
                switch ns.substring(with: m.range(at: 2)) {
                case "passed", "passing": out.passed = n
                case "failed", "failing": out.failed = n
                default: out.skipped = n
                }
            }
            break
        }
        if out.failures.isEmpty {
            out.failures = out.cases.filter { $0.result == .fail }.prefix(4).map { [$0.suite, $0.name].compactMap { $0 }.joined(separator: " › ") }
        }
        out.failures = Array(out.failures.prefix(4))
        return out
    }
}

// MARK: - Commands

struct CommandRun: Identifiable, Equatable {
    let id: Int
    let command: String
    let start: Double          // event time (ms)
    var end: Double?
    var exit: Int?
    var ok: Bool?
    var timed: Bool            // start and end came from separate events, so the duration is real
    let test: Bool
    let build: Bool
    var lost = false           // never reported a result
    var running: Bool { ok == nil && !lost }
    /// Seconds, only when the events measured it.
    var duration: Double? { timed ? end.map { max(0, $0 - start) / 1000 } : nil }

    private static let buildRe = try! NSRegularExpression(pattern: #"\b(xcodebuild|swift build|cargo build|npm run build|pnpm (run )?build|yarn build|vite build|next build|make|cmake --build|gradle|gradlew|tsc|docker build|go build)\b|godot .*--export"#)
    static func isBuild(_ cmd: String) -> Bool {
        buildRe.firstMatch(in: cmd, range: NSRange(location: 0, length: (cmd as NSString).length)) != nil
    }

    /// Ring fill: log-scaled duration relative to the slowest run shown.
    static func ring(_ d: Double, longest: Double) -> Double {
        guard longest > 0 else { return 0 }
        return min(1, log1p(d) / log1p(longest))
    }
}

// MARK: - Diff

struct DiffSplit: Identifiable, Equatable {
    struct Hunk: Identifiable, Equatable { let id: Int; let line: Int; let before: [String]; let after: [String] }
    let id: Int
    let path: String
    let hunks: [Hunk]
    var added: Int { hunks.reduce(0) { $0 + $1.after.count } }
    var removed: Int { hunks.reduce(0) { $0 + $1.before.count } }

    static func from(_ s: EditScript, path: String, id: Int, limit: Int = 6) -> DiffSplit {
        DiffSplit(id: id, path: path, hunks: s.ops.prefix(limit).enumerated().map { i, o in
            Hunk(id: i, line: o.line, before: Array(o.remove.prefix(40)), after: Array(o.insert.prefix(40)))
        })
    }
}

// MARK: - Files touched

struct FileHeat: Identifiable, Equatable {
    var id: String { path }
    let path: String
    var reads = 0
    var edits = 0
    var last = 0          // recency stamp (higher = more recent)
    var weight: Double { Double(reads) + 3 * Double(edits) }
}

enum HeatMap {
    /// The most-touched files, heaviest first, for the treemap.
    static func top(_ heat: [String: FileHeat], limit: Int = 24) -> [FileHeat] {
        Array(heat.values.sorted { ($0.weight, $0.last, $0.path) > ($1.weight, $1.last, $1.path) }.prefix(limit))
    }
    /// 0…1: how recently a file was touched compared to the newest touch.
    static func recency(_ f: FileHeat, newest: Int, span: Int = 12) -> Double {
        max(0, 1 - Double(newest - f.last) / Double(span))
    }
}
