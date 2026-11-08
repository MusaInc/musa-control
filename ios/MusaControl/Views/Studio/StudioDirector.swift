import SwiftUI
import UIKit

/// Fixed metrics for the studio stage. Everything on the stage is drawn with
/// these, so the director can work out exactly where a line of code, a file
/// row or the terminal prompt is and move the agent's cursor there.
enum StudioMetrics {
    static let codeFont = UIFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    static let termFont = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let codeCharW: CGFloat = ("M" as NSString).size(withAttributes: [.font: codeFont]).width
    static let termCharW: CGFloat = ("M" as NSString).size(withAttributes: [.font: termFont]).width
    static let lineH: CGFloat = 19
    static let termLineH: CGFloat = 17
    static let rowH: CGFloat = 25
    static let chrome: CGFloat = 30        // window title bar
    static let tabBar: CGFloat = 30        // editor tabs
    static let codeTop: CGFloat = 6
    static let gutter: CGFloat = 44
    static let codePad: CGFloat = 10
    static let explorerSearch: CGFloat = 36
    static let termPad: CGFloat = 10
}

struct EdLine: Identifiable, Equatable {
    enum Mark: Equatable { case none, added, selected, typing }
    let id: Int
    var text: String
    var mark: Mark = .none
    var sel: Range<Int>? = nil
}

struct TreeRow: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let name: String
    let depth: Int
    let dir: Bool
    var open = false
}

struct TermLine: Identifiable, Equatable {
    enum Kind: Equatable { case command, output, ok, fail, note }
    let id: Int
    let text: String
    let kind: Kind
}

struct PlanStep: Identifiable, Equatable { let id: Int; let text: String; let status: String }

struct StudioPhoto: Identifiable, Equatable {
    let id: String
    let title: String
    let path: String
    let query: [String: String?]
}

struct Caret: Equatable { var line: Int; var col: Int }
struct Stamp: Equatable { let id: Int; let text: String; let ok: Bool }

// MARK: - Edit scripts

/// One change to a document, in forward order: at `line` (in the document as
/// it is when the op runs), `remove` lines are replaced by `insert` lines.
struct EditOp: Equatable { var line: Int; var remove: [String]; var insert: [String] }
struct EditScript: Equatable { var before: [String]; var ops: [EditOp]; var tail: [String] = [] }

/// Turns what the agent really changed (Claude Code old/new strings, Codex
/// unified diffs, whole-file writes) into a before-document plus the ops that
/// the editor animates, so the typing on screen is the actual edit.
enum EditScripts {
    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\t", with: "    ")
    }
    static func lines(_ s: String) -> [String] { clean(s).components(separatedBy: "\n") }

    static func replacements(_ edits: [(old: String, new: String)], current: String?) -> EditScript? {
        guard !edits.isEmpty else { return nil }
        let edits = edits.map { (old: clean($0.old), new: clean($0.new)) }
        if let current {
            var text = clean(current)
            var ok = true
            // Undo the edits (last first) to get the file as it was before.
            for e in edits.reversed() {
                guard !e.new.isEmpty, let r = text.range(of: e.new) else { ok = false; break }
                text.replaceSubrange(r, with: e.old)
            }
            if ok {
                let before = text.components(separatedBy: "\n")
                var ops: [EditOp] = []
                for e in edits {
                    guard !e.old.isEmpty, let r = text.range(of: e.old) else { ok = false; break }
                    ops.append(op(in: text, range: r, with: e.new))
                    text.replaceSubrange(r, with: e.new)
                }
                if ok { return EditScript(before: before, ops: ops) }
            }
        }
        // Can't place it in the file (outside a project, or changed since):
        // show the snippet itself being rewritten.
        let e = edits[0]
        let old = e.old.components(separatedBy: "\n"), new = e.new.components(separatedBy: "\n")
        return EditScript(before: old, ops: [trimmed(EditOp(line: 0, remove: old, insert: new))])
    }

    static func op(in text: String, range r: Range<String.Index>, with new: String) -> EditOp {
        let head = text[..<r.lowerBound]
        let line = head.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        let lineStart = head.lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let lineEnd = text[r.upperBound...].firstIndex(of: "\n") ?? text.endIndex
        let pre = String(text[lineStart..<r.lowerBound]), post = String(text[r.upperBound..<lineEnd])
        let old = String(text[r])
        return trimmed(EditOp(line: line,
                              remove: (pre + old + post).components(separatedBy: "\n"),
                              insert: (pre + new + post).components(separatedBy: "\n")))
    }

    /// Drops unchanged lines at both ends so only the real change animates.
    static func trimmed(_ o: EditOp) -> EditOp {
        var o = o
        while let a = o.remove.first, let b = o.insert.first, a == b, o.remove.count > 1 || o.insert.count > 1 {
            o.remove.removeFirst(); o.insert.removeFirst(); o.line += 1
        }
        while let a = o.remove.last, let b = o.insert.last, a == b, o.remove.count > 1 || o.insert.count > 1 {
            o.remove.removeLast(); o.insert.removeLast()
        }
        return o
    }

    static func hunkNewStart(_ s: String) -> Int {
        let parts = s.split(separator: " ")
        guard parts.count >= 3, parts[2].hasPrefix("+") else { return 1 }
        return Int(parts[2].dropFirst().split(separator: ",").first ?? "1") ?? 1
    }

    static func diff(_ raw: String, current: String?) -> EditScript? {
        let text = raw.hasPrefix("---") || raw.hasPrefix("diff ") ? raw : "--- a/file\n+++ b/file\n" + raw
        guard let file = DiffParser.parse(text).first, !file.lines.isEmpty else { return nil }
        var ops: [EditOp] = []          // positions in the full file
        var snippet: [String] = []      // fallback document: context + removed lines
        var snippetOps: [EditOp] = []
        var pos = 0, spos = 0
        var run: EditOp?, srun: EditOp?
        func flush() {
            if let r = run { ops.append(r) }
            if let r = srun { snippetOps.append(r) }
            run = nil; srun = nil
        }
        for l in file.lines {
            switch l.kind {
            case .hunk:
                flush()
                pos = max(0, hunkNewStart(l.text) - 1)
                if !snippet.isEmpty { snippet.append("⋯"); spos += 1 }
            case .context:
                flush(); pos += 1; spos += 1
                snippet.append(clean(l.text))
            case .removed:
                if run == nil { run = EditOp(line: pos, remove: [], insert: []); srun = EditOp(line: spos, remove: [], insert: []) }
                run?.remove.append(clean(l.text)); srun?.remove.append(clean(l.text))
                snippet.append(clean(l.text))
            case .added:
                if run == nil { run = EditOp(line: pos, remove: [], insert: []); srun = EditOp(line: spos, remove: [], insert: []) }
                run?.insert.append(clean(l.text)); srun?.insert.append(clean(l.text))
                pos += 1; spos += 1
            case .meta:
                continue
            }
        }
        flush()
        if let current, !ops.isEmpty {
            var doc = lines(current)
            var ok = true
            for o in ops.reversed() {
                guard o.line >= 0, o.line + o.insert.count <= doc.count else { ok = false; break }
                doc.replaceSubrange(o.line..<(o.line + o.insert.count), with: o.remove)
            }
            if ok { return EditScript(before: doc, ops: ops.map(trimmed)) }
        }
        guard !snippetOps.isEmpty else { return nil }
        return EditScript(before: snippet, ops: snippetOps.map(trimmed))
    }

    /// A new file: type the top of it, then the rest lands at once.
    static func typing(_ current: String) -> EditScript {
        let all = lines(current)
        return EditScript(before: [], ops: [EditOp(line: 0, remove: [], insert: Array(all.prefix(32)))], tail: Array(all.dropFirst(32)))
    }
}

// MARK: - Director

/// Plays an agent's real activity (from its transcript events) as a person
/// working at a desk: the cursor finds files in the explorer, opens them,
/// selects and retypes the exact lines that changed, runs the exact commands
/// in the terminal and streams their real output. Nothing is invented — every
/// scene is one event; when the agent is quiet the stage rests.
@MainActor
@Observable
final class StudioDirector {
    typealias M = StudioMetrics
    enum Mode: Equatable { case loading, catchingUp, live }
    enum CursorStyle: Equatable { case arrow, ibeam, hand }
    enum Region: Hashable { case stage, explorer, editor, terminal, thought }

    let agentId: String
    private let client: GatewayClient
    @ObservationIgnored var locator: (@MainActor (String) -> (project: Project, rel: String)?)?
    @ObservationIgnored private var projectId: String?
    @ObservationIgnored private var root: String?
    @ObservationIgnored var reduceMotion = false

    var rootName = "workspace"
    var frames: [Region: CGRect] = [:]
    var showExplorer = true

    // Cursor
    var cursor = CGPoint(x: 280, y: 240)
    var cursorStyle: CursorStyle = .arrow
    var clickTick = 0
    var focus: Region?                     // window the cursor is working in

    // Explorer
    var tree: [TreeRow] = []
    var treeScroll: CGFloat = 0
    var activeRow: String?
    var searchText: String?
    var quickOpen: String?

    // Editor
    var tabs: [String] = []
    var openPath: String?
    var lines: [EdLine] = []
    var scrollY: CGFloat = 0
    var scrollX: CGFloat = 0
    var caret: Caret?
    var readLine: Int?
    var editorNote: String?
    var modified = false
    var savedTick = 0

    // Terminal
    var term: [TermLine] = []
    var termTyping: String?
    var termBusy = false
    var shakeTick = 0
    var stamp: Stamp?

    // Side
    var thought = ""
    var thoughtDone = true
    var plan: [PlanStep] = []
    var photos: [StudioPhoto] = []
    var heroPhoto: StudioPhoto?
    var instruction: String?
    var ticker: [TimelineEvent] = []

    // Status
    var caption = "Getting ready"
    var captionIcon = "sparkles"
    var mode: Mode = .loading
    var busy = false
    var queued = 0
    var celebrateTick = 0

    @ObservationIgnored private var queue: [TimelineEvent] = []
    @ObservationIgnored private var seen = Set<String>()
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var seq = 0
    @ObservationIgnored private var lastCommand: String?
    @ObservationIgnored private var history: [TimelineEvent] = []

    init(agentId: String, client: GatewayClient) {
        self.agentId = agentId
        self.client = client
    }

    var prompt: String { "\(rootName) $ " }

    // MARK: Lifecycle

    func start(project: Project?, cwd: String?) async {
        root = project?.path
        projectId = project?.id
        rootName = project?.name ?? (cwd.map { ($0 as NSString).lastPathComponent } ?? "workspace")
        if let root, projectId != nil { tree = await listing(of: root, depth: 0) }
        let evs = (try? await client.get("/api/agents/\(agentId.pathSegment)/timeline", ["limit": "160"], as: [TimelineEvent].self)) ?? []
        history = evs.sorted { $0.ts < $1.ts }
        for e in history { seen.insert(e.stableId) }
        let replay = Array(history.filter(Self.isScene).suffix(6))
        let cutoff = replay.first?.ts ?? .infinity
        prime(history.filter { $0.ts < cutoff })
        if replay.isEmpty {
            mode = .live
            setCaption("Waiting for the agent's next move", icon: "cup.and.saucer")
        } else {
            mode = .catchingUp
            enqueue(replay)
        }
    }

    /// New live events for this agent (already-seen ones are ignored).
    func ingest(_ evs: [TimelineEvent]) {
        guard mode != .loading || !history.isEmpty else { return }
        let fresh = evs.filter { $0.session == agentId && seen.insert($0.stableId).inserted }.sorted { $0.ts < $1.ts }
        guard !fresh.isEmpty else { return }
        if mode == .catchingUp, fresh.contains(where: Self.isScene) { mode = .live }
        enqueue(fresh)
    }

    /// Replay the agent's most recent actions again.
    func replay() {
        let recent = Array(history.filter(Self.isScene).suffix(8))
        guard !recent.isEmpty, !busy else { return }
        mode = .catchingUp
        enqueue(recent)
    }

    func stop() {
        runner?.cancel(); runner = nil
        queue.removeAll(); queued = 0; busy = false
    }

    private func enqueue(_ evs: [TimelineEvent]) {
        queue.append(contentsOf: evs)
        if queue.count > 24 { queue.removeFirst(queue.count - 16) }   // far behind: skip ahead
        queued = queue.count
        if runner == nil { runner = Task { [weak self] in await self?.run() } }
    }

    private func run() async {
        busy = true
        while !Task.isCancelled, !queue.isEmpty {
            let e = queue.removeFirst()
            queued = queue.count
            if !history.contains(where: { $0.stableId == e.stableId }) { history.append(e); if history.count > 400 { history.removeFirst(100) } }
            withAnimation(.snappy(duration: 0.3)) {
                ticker.append(e)
                if ticker.count > 7 { ticker.removeFirst(ticker.count - 7) }
            }
            await play(e)
        }
        runner = nil
        busy = false
        if !Task.isCancelled {
            mode = .live
            readLine = nil
            cursorStyle = .arrow
        }
    }

    // MARK: Timing

    private var speed: Double {
        if reduceMotion { return 12 }
        let base: Double
        switch queue.count {
        case 0...1: base = 1
        case 2...3: base = 1.6
        case 4...8: base = 2.6
        default: base = 5
        }
        return mode == .catchingUp ? base * 1.5 : base
    }
    private func wait(_ s: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, s / speed) * 1_000_000_000))
    }
    private var cancelled: Bool { Task.isCancelled }

    private func setCaption(_ text: String, icon: String) {
        withAnimation(.snappy(duration: 0.25)) { caption = text; captionIcon = icon }
    }

    // MARK: Cursor

    private func move(to p: CGPoint, style: CursorStyle? = nil) async {
        if let style { cursorStyle = style }
        let f = [Region.explorer, .editor, .terminal, .thought].first { frames[$0]?.contains(p) == true }
        if f != focus { focus = f }
        let d = hypot(p.x - cursor.x, p.y - cursor.y)
        guard d > 1 else { return }
        let t = min(0.85, max(0.22, Double(d) / 1100 + 0.18))
        withAnimation(.timingCurve(0.3, 0, 0.2, 1, duration: t / speed)) { cursor = p }
        await wait(t)
    }
    private func nudge(to p: CGPoint) { withAnimation(.linear(duration: 0.07)) { cursor = p } }
    private func click() async { clickTick &+= 1; await wait(0.16) }

    // MARK: Geometry (stage coordinates)

    private func rect(_ r: Region) -> CGRect { frames[r] ?? frames[.stage] ?? CGRect(x: 0, y: 0, width: 900, height: 600) }
    var visibleLines: Int { max(4, Int((rect(.editor).height - M.chrome - M.tabBar - M.codeTop) / M.lineH)) }
    var visibleRows: Int { max(3, Int((rect(.explorer).height - M.chrome - M.explorerSearch) / M.rowH)) }

    func linePoint(_ line: Int, col: Int) -> CGPoint {
        let f = rect(.editor)
        let x = f.minX + M.gutter + M.codePad + CGFloat(col) * M.codeCharW - scrollX
        return CGPoint(x: min(f.maxX - 12, max(f.minX + M.gutter, x)),
                       y: f.minY + M.chrome + M.tabBar + M.codeTop + CGFloat(line) * M.lineH - scrollY + M.lineH / 2)
    }
    private func rowPoint(_ i: Int) -> CGPoint {
        let f = rect(.explorer)
        let depth = tree.indices.contains(i) ? tree[i].depth : 0
        return CGPoint(x: min(f.maxX - 24, f.minX + 48 + CGFloat(depth) * 12 + 24),
                       y: f.minY + M.chrome + M.explorerSearch + CGFloat(i) * M.rowH - treeScroll + M.rowH / 2)
    }
    private var searchPoint: CGPoint { let f = rect(.explorer); return CGPoint(x: f.minX + 70, y: f.minY + M.chrome + M.explorerSearch / 2) }
    private func termPoint(col: Int) -> CGPoint {
        let f = rect(.terminal)
        return CGPoint(x: min(f.maxX - 16, f.minX + M.termPad + CGFloat(col) * M.termCharW), y: f.maxY - M.termPad - M.termLineH / 2)
    }
    private var quickOpenPoint: CGPoint { let f = rect(.editor); return CGPoint(x: f.midX - 40, y: f.minY + M.chrome + M.tabBar + 30) }

    // MARK: Scenes

    static func isScene(_ e: TimelineEvent) -> Bool {
        ["agent.edit", "agent.read", "agent.command", "agent.test", "agent.command_done", "agent.command_failed",
         "agent.message", "agent.plan", "agent.image", "agent.prompt", "agent.tool"].contains(e.kind)
    }

    private func play(_ e: TimelineEvent) async {
        switch e.kind {
        case "agent.edit": await playEdit(e)
        case "agent.read": await playRead(e)
        case "agent.command", "agent.test": await playCommand(e)
        case "agent.command_done", "agent.command_failed": await playCommandDone(e)
        case "agent.message": await playMessage(e)
        case "agent.plan": await playPlan(e)
        case "agent.image": await playImage(e)
        case "agent.prompt": await playPrompt(e)
        case "agent.tool": await playTool(e)
        case "agent.done":
            setCaption("Finished this turn", icon: "checkmark.seal")
            celebrateTick &+= 1
            await wait(1.4)
        case "agent.error":
            setCaption(e.title, icon: "exclamationmark.triangle")
            shakeTick &+= 1
            await wait(1)
        case "agent.approval":
            setCaption("Asking for your approval", icon: "hand.raised")
            let f = rect(.stage)
            await move(to: CGPoint(x: f.midX, y: f.maxY - 120), style: .hand)
        case "agent.started":
            setCaption("Started", icon: "play.circle"); await wait(0.5)
        case "agent.stopped", "agent.ended":
            setCaption(e.title, icon: "stop.circle"); await wait(0.5)
        default:
            await wait(0.15)
        }
    }

    // Explorer / opening files

    private func listing(of abs: String, depth: Int, keep: String? = nil) async -> [TreeRow] {
        guard let root, let pid = projectId else { return [] }
        let rel = abs == root ? "" : String(abs.dropFirst(root.count + 1))
        guard let l = try? await client.get("/api/projects/\(pid)/files", ["path": rel], as: DirListing.self) else { return [] }
        let keepRel = keep.map { $0 == root ? "" : String($0.dropFirst(root.count + 1)) }
        var entries = l.entries.filter { e in
            (e.path as NSString).deletingLastPathComponent == rel && ((e.hidden != true && e.ignored != true) || e.path == keepRel)
        }
        if entries.count > 40 {
            var cut = Array(entries.prefix(40))
            if let k = keepRel, !cut.contains(where: { $0.path == k }), let e = entries.first(where: { $0.path == k }) { cut.append(e) }
            entries = cut
        }
        return entries.map { TreeRow(path: root + "/" + $0.path, name: $0.name, depth: depth, dir: $0.dir) }
    }

    private func collapse(keeping keep: Set<String>) {
        var out: [TreeRow] = []
        var hideDeeperThan: Int?
        for r in tree {
            var r = r
            if let d = hideDeeperThan { if r.depth > d { continue } else { hideDeeperThan = nil } }
            if r.dir && r.open && !keep.contains(r.path) { r.open = false; hideDeeperThan = r.depth }
            out.append(r)
        }
        if out != tree { withAnimation(.easeOut(duration: 0.2)) { tree = out } }
    }

    private func ensureRow(_ path: String, name: String, depth: Int, dir: Bool, parent: String) -> Int {
        if let i = tree.firstIndex(where: { $0.path == path }) { return i }
        var at = tree.count
        if let p = tree.firstIndex(where: { $0.path == parent }) {
            at = p + 1
            while at < tree.count, tree[at].depth > tree[p].depth { at += 1 }
        }
        withAnimation(.easeOut(duration: 0.2)) { tree.insert(TreeRow(path: path, name: name, depth: depth, dir: dir), at: at) }
        return at
    }

    private func expand(_ idx: Int, toward next: String) async {
        guard tree.indices.contains(idx) else { return }
        let row = tree[idx]
        let kids = await listing(of: row.path, depth: row.depth + 1, keep: next)
        guard let i = tree.firstIndex(where: { $0.path == row.path }) else { return }
        let existing = Set(tree.map(\.path))
        withAnimation(.easeOut(duration: 0.22 / speed)) {
            tree[i].open = true
            tree.insert(contentsOf: kids.filter { !existing.contains($0.path) }, at: i + 1)
        }
        await wait(0.24)
    }

    private func revealRow(_ idx: Int) async {
        let top = CGFloat(idx) * M.rowH
        let h = CGFloat(visibleRows) * M.rowH
        var t = treeScroll
        if top < treeScroll + M.rowH { t = max(0, top - M.rowH * 2) }
        else if top > treeScroll + h - M.rowH * 2 { t = top - h + M.rowH * 3 }
        guard t != treeScroll else { return }
        withAnimation(.easeInOut(duration: 0.3 / speed)) { treeScroll = t }
        await wait(0.3)
    }

    /// Find the file the way a person would: through the folders in the
    /// explorer, or (no explorer / outside the project) with quick open.
    private func locate(_ abs: String) async {
        if openPath == abs { return }
        let name = (abs as NSString).lastPathComponent
        setCaption("Looking for \(name)", icon: "magnifyingglass")
        if showExplorer, let root, projectId != nil, abs.hasPrefix(root + "/") {
            let comps = abs.dropFirst(root.count + 1).split(separator: "/").map(String.init)
            var ancestors = Set<String>()
            var cur = root
            for c in comps.dropLast() { cur += "/" + c; ancestors.insert(cur) }
            collapse(keeping: ancestors)
            cur = root
            for (i, c) in comps.enumerated() {
                if cancelled { return }
                let path = cur + "/" + c
                let last = i == comps.count - 1
                let idx = ensureRow(path, name: c, depth: i, dir: !last, parent: cur)
                await revealRow(idx)
                await move(to: rowPoint(idx), style: .arrow)
                withAnimation(.easeOut(duration: 0.15)) { activeRow = path }
                await click()
                if !last, tree.indices.contains(idx), !tree[idx].open {
                    await expand(idx, toward: cur + "/" + c + "/" + comps[i + 1])
                }
                cur = path
            }
        } else {
            await move(to: quickOpenPoint, style: .arrow)
            await click()
            quickOpen = ""
            var typed = ""
            for ch in name {
                if cancelled { break }
                typed.append(ch); quickOpen = typed
                await wait(Double.random(in: 0.02...0.05))
            }
            await wait(0.35)
            quickOpen = nil
        }
        withAnimation(.snappy(duration: 0.2)) {
            if !tabs.contains(abs) { tabs.append(abs); if tabs.count > 5 { tabs.removeFirst() } }
            openPath = abs
        }
    }

    private func content(_ abs: String) async -> String? {
        guard let loc = locator?(abs) else { return nil }
        guard let f = try? await client.get("/api/projects/\(loc.project.id)/file", ["path": loc.rel], as: FileContent.self), !f.binary else { return nil }
        return f.text
    }

    private func showDoc(_ doc: [String], note: String? = nil) {
        var out: [EdLine] = []
        out.reserveCapacity(doc.count)
        for l in doc { seq += 1; out.append(EdLine(id: seq, text: l)) }
        withAnimation(.easeOut(duration: 0.2)) {
            lines = out
            scrollY = 0; scrollX = 0
            caret = nil; readLine = nil
            editorNote = note
        }
    }

    // Editor scrolling

    private func reveal(_ line: Int) async {
        let top = scrollY / M.lineH, vis = CGFloat(visibleLines)
        guard CGFloat(line) < top + 2 || CGFloat(line) > top + vis - 4 else { return }
        let maxTop = max(0, CGFloat(lines.count) - vis + 2)
        let t = min(max(0, CGFloat(line) - vis / 3), maxTop)
        withAnimation(.easeInOut(duration: 0.45 / speed)) { scrollY = t * M.lineH }
        await wait(0.45)
    }
    private func follow(_ line: Int) {
        let top = scrollY / M.lineH, vis = CGFloat(visibleLines)
        var t = top
        if CGFloat(line) > top + vis * 0.72 { t = CGFloat(line) - vis * 0.72 }
        else if CGFloat(line) < top + 1 { t = CGFloat(line) - 2 }
        t = max(0, min(t, max(0, CGFloat(lines.count) - vis + 2)))
        if t != top { withAnimation(.linear(duration: 0.1)) { scrollY = t * M.lineH } }
    }
    private func followCol(_ col: Int) {
        let width = rect(.editor).width - M.gutter - M.codePad - 40
        let x = CGFloat(col) * M.codeCharW
        var t = scrollX
        if x - scrollX > width { t = x - width * 0.7 } else if x < scrollX { t = max(0, x - 60) }
        if t != scrollX { withAnimation(.easeOut(duration: 0.15)) { scrollX = t } }
    }

    private func indent(_ s: String) -> Int { s.prefix(while: { $0 == " " }).count }

    // Read

    private func playRead(_ e: TimelineEvent) async {
        guard let path = e.detail?["path"]?.string else { return }
        let name = (path as NSString).lastPathComponent
        let wasOpen = openPath == path && !lines.isEmpty
        await locate(path)
        setCaption("Reading \(name)", icon: "eyes")
        if !wasOpen {
            if let t = await content(path) { showDoc(EditScripts.lines(t)) }
            else { showDoc([], note: "\(name) isn't inside a project, so its contents can't be shown here.") }
        }
        guard !lines.isEmpty else { await wait(0.9); return }
        let start = max(0, min(Int(scrollY / M.lineH), lines.count - 1))
        let stop = min(lines.count - 1, start + max(visibleLines + 20, 60))
        await move(to: linePoint(start, col: indent(lines[start].text)), style: .ibeam)
        for l in stride(from: start, through: stop, by: 2) {
            if cancelled { break }
            readLine = l
            follow(l)
            nudge(to: linePoint(l, col: indent(lines[l].text) + min(lines[l].text.count - indent(lines[l].text), 14)))
            await wait(0.055)
        }
        withAnimation(.easeOut(duration: 0.3)) { readLine = nil }
    }

    // Edit

    private func playEdit(_ e: TimelineEvent) async {
        guard let path = e.detail?["path"]?.string else { return }
        let name = (path as NSString).lastPathComponent
        await locate(path)
        let change = e.detail?["change"]?.string
        setCaption(change == "add" || e.detail?["tool"]?.string == "Write" ? "Writing \(name)" : change == "delete" ? "Deleting \(name)" : "Editing \(name)", icon: "pencil.line")
        let current = await content(path)
        let edits: [(old: String, new: String)] = (e.detail?["edits"]?.array ?? []).compactMap { v in
            guard let o = v["old"]?.string, let n = v["new"]?.string else { return nil }
            return (old: o, new: n)
        }
        var script: EditScript?
        if !edits.isEmpty { script = EditScripts.replacements(edits, current: current) }
        else if let d = e.detail?["diff"]?.string, !d.isEmpty { script = EditScripts.diff(d, current: current) }
        else if let current, e.detail?["tool"]?.string == "Write" || change == "add" { script = EditScripts.typing(current) }

        if change == "delete" {
            if lines.isEmpty, let s = script { showDoc(s.before) }
            if !lines.isEmpty {
                await selectBlock(at: 0, count: min(lines.count, visibleLines))
                withAnimation(.easeOut(duration: 0.25)) { lines.removeAll() }
            }
            withAnimation { tabs.removeAll { $0 == path }; editorNote = "\(name) was deleted." }
            await wait(0.8)
            return
        }
        guard let script else {
            if let current { showDoc(EditScripts.lines(current)) }
            await wait(0.8)
            return
        }
        showDoc(script.before)
        modified = true
        for (i, op) in script.ops.enumerated() {
            if cancelled { break }
            if i < 6 { await perform(op) } else { applyInstantly(op) }
        }
        if !script.tail.isEmpty {
            var extra: [EdLine] = []
            for l in script.tail { seq += 1; extra.append(EdLine(id: seq, text: l, mark: .added)) }
            withAnimation(.easeOut(duration: 0.3)) { lines.append(contentsOf: extra) }
        }
        await wait(0.3)
        modified = false
        savedTick &+= 1
        await wait(0.5)
    }

    private func applyInstantly(_ op: EditOp) {
        let at = min(max(0, op.line), lines.count)
        let n = min(op.remove.count, lines.count - at)
        var add: [EdLine] = []
        for l in op.insert { seq += 1; add.append(EdLine(id: seq, text: l, mark: .added)) }
        withAnimation(.easeOut(duration: 0.2)) {
            lines.removeSubrange(at..<(at + n))
            lines.insert(contentsOf: add, at: at)
        }
    }

    private func selectBlock(at: Int, count n: Int) async {
        guard n > 0, at < lines.count else { return }
        await move(to: linePoint(at, col: 0), style: .ibeam)
        await click()
        caret = Caret(line: at, col: 0)
        for k in 0..<n where at + k < lines.count {
            lines[at + k].mark = .selected
            follow(at + k)
            nudge(to: linePoint(at + k, col: min(lines[at + k].text.count, 48)))
            await wait(min(0.07, 0.9 / Double(n)))
        }
        await wait(0.3)
    }

    private func perform(_ op: EditOp) async {
        let at = min(max(0, op.line), lines.count)
        await reveal(at)
        if op.remove.count == 1, op.insert.count == 1, at < lines.count {
            await retype(line: at, from: op.remove[0], to: op.insert[0])
            return
        }
        if !op.remove.isEmpty, at < lines.count {
            let n = min(op.remove.count, lines.count - at)
            await selectBlock(at: at, count: n)
            withAnimation(.easeOut(duration: 0.2 / speed)) { lines.removeSubrange(at..<(at + n)) }
            await wait(0.2)
        } else {
            let anchor = max(0, at - 1)
            let col = lines.indices.contains(anchor) ? lines[anchor].text.count : 0
            followCol(col)
            await move(to: linePoint(anchor, col: col), style: .ibeam)
            await click()
        }
        let total = max(1, op.insert.reduce(0) { $0 + $1.count })
        let budget = min(5.5, max(0.7, Double(total) / 42))
        let perChar = budget / Double(total)
        let chunk = perChar < 0.014 ? Int((0.014 / perChar).rounded(.up)) : 1
        for (k, text) in op.insert.enumerated() {
            if cancelled { break }
            let li = min(at + k, lines.count)
            seq += 1
            withAnimation(.easeOut(duration: 0.12 / speed)) { lines.insert(EdLine(id: seq, text: "", mark: .typing), at: li) }
            follow(li)
            await typeInto(line: li, insert: text, at: 0, chunk: chunk, perChar: perChar)
            if lines.indices.contains(li) { lines[li].mark = .added }
        }
    }

    /// One line changed: select just the part that differs and type the new part.
    private func retype(line li: Int, from old: String, to new: String) async {
        let o = Array(old), n = Array(new)
        var p = 0
        while p < o.count, p < n.count, o[p] == n[p] { p += 1 }
        var s = 0
        while s < o.count - p, s < n.count - p, o[o.count - 1 - s] == n[n.count - 1 - s] { s += 1 }
        lines[li].text = old
        followCol(p)
        await move(to: linePoint(li, col: p), style: .ibeam)
        await click()
        caret = Caret(line: li, col: p)
        let cut = o.count - s - p
        if cut > 0 {
            let steps = min(cut, 14)
            for k in 1...steps {
                if cancelled { break }
                let c = p + cut * k / steps
                lines[li].sel = p..<c
                nudge(to: linePoint(li, col: c))
                await wait(0.03)
            }
            await wait(0.22)
            lines[li].sel = nil
            lines[li].text = String(o[..<p]) + String(o[(o.count - s)...])
            caret = Caret(line: li, col: p)
            await wait(0.12)
        }
        lines[li].mark = .typing
        let mid = String(n[p..<(n.count - s)])
        await typeInto(line: li, insert: mid, at: p, chunk: 1, perChar: min(0.055, 2.6 / Double(max(mid.count, 1))))
        if lines.indices.contains(li) { lines[li].mark = .added }
    }

    private func typeInto(line li: Int, insert: String, at col: Int, chunk: Int, perChar: Double) async {
        guard lines.indices.contains(li) else { return }
        var chars = Array(insert)
        let base = Array(lines[li].text)
        let pos = min(col, base.count)
        var head = Array(base.prefix(pos))
        let tail = Array(base.dropFirst(pos))
        if pos == 0 {
            // Auto-indent: leading spaces land at once.
            let ind = chars.prefix(while: { $0 == " " }).count
            head += chars.prefix(ind)
            chars.removeFirst(ind)
        }
        lines[li].text = String(head + tail)
        caret = Caret(line: li, col: head.count)
        followCol(head.count)
        var i = 0
        while i < chars.count, !cancelled {
            let j = min(chars.count, i + chunk)
            head += chars[i..<j]
            i = j
            guard lines.indices.contains(li) else { return }
            lines[li].text = String(head + tail)
            caret = Caret(line: li, col: head.count)
            followCol(head.count)
            var d = perChar * Double(chunk) * Double.random(in: 0.45...1.6)
            if let last = head.last, "{;(,".contains(last), chunk == 1, Int.random(in: 0..<4) == 0 { d += 0.12 }
            await wait(d)
        }
    }

    // Terminal

    private func appendTerm(_ text: String, _ kind: TermLine.Kind) {
        seq += 1
        term.append(TermLine(id: seq, text: text, kind: kind))
        if term.count > 120 { term.removeFirst(term.count - 120) }
    }

    static func oneLine(_ s: String, _ n: Int) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ⏎ ").replacingOccurrences(of: "\t", with: " ")
        return t.count > n ? String(t.prefix(n - 1)) + "…" : t
    }
    static func stripAnsi(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
    }

    private func typeCommand(_ raw: String) async {
        let cmd = Self.oneLine(raw, 260)
        lastCommand = raw
        termBusy = false
        await move(to: termPoint(col: prompt.count), style: .ibeam)
        await click()
        termTyping = ""
        let chunk = max(1, cmd.count / 70)
        var typed = ""
        var i = cmd.startIndex
        while i < cmd.endIndex, !cancelled {
            let j = cmd.index(i, offsetBy: chunk, limitedBy: cmd.endIndex) ?? cmd.endIndex
            typed += cmd[i..<j]
            i = j
            termTyping = typed
            nudge(to: termPoint(col: prompt.count + typed.count))
            await wait(Double.random(in: 0.012...0.042))
        }
        await wait(0.2)
        appendTerm(prompt + cmd, .command)
        termTyping = nil
    }

    private func streamOutput(_ out: String, ok: Bool, exit: Int?, test: Bool) async {
        termBusy = false
        let all = out.components(separatedBy: "\n").map { Self.stripAnsi($0) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let tail = Array(all.suffix(12))
        if all.count > tail.count { appendTerm("… \(all.count - tail.count) earlier lines", .note) }
        for l in tail {
            if cancelled { break }
            withAnimation(.easeOut(duration: 0.12)) { appendTerm(String(l.prefix(300)), .output) }
            await wait(0.045)
        }
        let code = exit.map { " (exit \($0))" } ?? ""
        withAnimation(.easeOut(duration: 0.15)) { appendTerm(ok ? "✓ done\(code)" : "✗ failed\(code)", ok ? .ok : .fail) }
        if !ok { shakeTick &+= 1 }
        if test, let s = Feed.testSummary(out) {
            seq += 1
            withAnimation(.spring(duration: 0.4, bounce: 0.45)) { stamp = Stamp(id: seq, text: s, ok: ok) }
            await wait(1.6)
            withAnimation(.easeOut(duration: 0.3)) { stamp = nil }
        } else {
            await wait(0.45)
        }
    }

    private func playCommand(_ e: TimelineEvent) async {
        let cmd = e.detail?["command"]?.string ?? e.title
        let test = e.kind == "agent.test"
        setCaption(test ? "Running the tests" : (e.detail?["description"]?.string ?? "Running a command"), icon: test ? "checklist" : "terminal")
        await typeCommand(cmd)
        if let out = e.detail?["output"]?.string {
            let code = e.detail?["exitCode"]?.number.map { Int($0) }
            await streamOutput(out, ok: code.map { $0 == 0 } ?? (e.detail?["ok"]?.bool ?? true), exit: code, test: test)
        } else {
            termBusy = true
            await wait(0.5)
        }
    }

    private func playCommandDone(_ e: TimelineEvent) async {
        let cmd = e.detail?["command"]?.string ?? ""
        if !cmd.isEmpty, cmd != lastCommand {
            setCaption("Running a command", icon: "terminal")
            await typeCommand(cmd)
        }
        let code = e.detail?["exitCode"]?.number.map { Int($0) }
        let ok = e.kind != "agent.command_failed" && (e.detail?["ok"]?.bool ?? true)
        setCaption(ok ? "Command finished" : "A command failed", icon: ok ? "checkmark.circle" : "xmark.octagon")
        await streamOutput(e.detail?["output"]?.string ?? "", ok: ok, exit: code, test: e.detail?["test"]?.bool == true)
    }

    // Thinking, plan, pictures, instructions, tools

    static func plainText(_ s: String, _ n: Int) -> String {
        var t = s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        t = t.replacingOccurrences(of: "(?m)^#+\\s*", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > n ? String(t.prefix(n - 1)) + "…" : t
    }

    private func playMessage(_ e: TimelineEvent) async {
        let text = Self.plainText(e.detail?["text"]?.string ?? e.title, 560)
        setCaption("Writing down what it found", icon: "text.bubble")
        if let f = frames[.thought] { await move(to: CGPoint(x: f.minX + 40, y: f.minY + 46), style: .arrow) }
        thought = ""
        thoughtDone = false
        let words = text.split(separator: " ", omittingEmptySubsequences: false)
        let per = min(0.07, 3.4 / Double(max(words.count, 1)))
        var out = ""
        for (i, w) in words.enumerated() {
            if cancelled { break }
            out += (i == 0 ? "" : " ") + w
            thought = out
            await wait(per * Double.random(in: 0.6...1.4))
        }
        thought = text
        thoughtDone = true
        await wait(0.7)
    }

    static func planSteps(_ e: TimelineEvent) -> [PlanStep] {
        (e.detail?["items"]?.array ?? []).enumerated().compactMap { i, v in
            guard let t = v["text"]?.string else { return nil }
            return PlanStep(id: i, text: t, status: v["status"]?.string ?? "pending")
        }
    }

    private func playPlan(_ e: TimelineEvent) async {
        let steps = Self.planSteps(e)
        setCaption("Updating the plan", icon: "list.bullet")
        if plan.map(\.text) == steps.map(\.text) {
            for (i, s) in steps.enumerated() where i < plan.count && plan[i].status != s.status {
                withAnimation(.spring(duration: 0.35, bounce: 0.4)) { plan[i] = s }
                await wait(0.25)
            }
        } else {
            withAnimation(.easeOut(duration: 0.2)) { plan = [] }
            for s in steps {
                if cancelled { break }
                withAnimation(.spring(duration: 0.3)) { plan.append(s) }
                await wait(0.12)
            }
        }
        await wait(0.6)
    }

    private func imageSource(_ path: String, session: String?) async -> (String, [String: String?])? {
        if let loc = locator?(path) { return ("/api/projects/\(loc.project.id)/thumb", ["path": loc.rel, "w": "900"]) }
        for _ in 0..<3 {
            if let list = try? await client.get("/api/screenshots", ["session": session, "limit": "100"], as: [Screenshot].self),
               let s = list.first(where: { $0.path == path }) {
                return ("/api/screenshots/\(s.id)/image", ["w": "900"])
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        return nil
    }

    private func playImage(_ e: TimelineEvent) async {
        guard let path = e.detail?["path"]?.string else { return }
        setCaption(e.detail?["via"]?.string == "command" ? "Took a screenshot" : "Looking at a picture", icon: "photo")
        guard let src = await imageSource(path, session: e.session) else { await wait(0.4); return }
        let p = StudioPhoto(id: e.stableId, title: (path as NSString).lastPathComponent, path: src.0, query: src.1)
        let f = rect(.stage)
        await move(to: CGPoint(x: f.midX + 40, y: f.midY + 60), style: .hand)
        withAnimation(.spring(duration: 0.55, bounce: 0.3)) { heroPhoto = p }
        await wait(2.8)
        withAnimation(.spring(duration: 0.5)) {
            heroPhoto = nil
            photos.removeAll { $0.id == p.id }
            photos.append(p)
            if photos.count > 3 { photos.removeFirst() }
        }
        await wait(0.4)
    }

    private func playPrompt(_ e: TimelineEvent) async {
        guard e.detail?["sidechain"]?.bool != true else { return }
        let text = Self.plainText(e.detail?["text"]?.string ?? e.title, 280)
        setCaption("Got a new instruction", icon: "text.bubble")
        withAnimation(.spring(duration: 0.45, bounce: 0.3)) { instruction = text }
        thought = ""
        thoughtDone = true
        await wait(2.6)
        withAnimation(.easeOut(duration: 0.3)) { instruction = nil }
        await wait(0.2)
    }

    private func playTool(_ e: TimelineEvent) async {
        let tool = e.detail?["tool"]?.string ?? ""
        let input = e.detail?["input"]?.string ?? ""
        var pattern: String?
        if let m = input.range(of: "\"(pattern|query)\":\"((?:[^\"\\\\]|\\\\.)*)\"", options: .regularExpression) {
            let s = String(input[m])
            if let colon = s.range(of: "\":\"") { pattern = String(s[colon.upperBound...].dropLast()) }
        }
        if tool == "web.search", e.title.hasPrefix("Web search: ") { pattern = String(e.title.dropFirst(12)) }
        if let pattern, ["Grep", "Glob", "LS", "web.search", "WebSearch"].contains(tool) {
            setCaption(tool.lowercased().contains("web") ? "Searching the web" : "Searching the code", icon: tool.lowercased().contains("web") ? "globe" : "magnifyingglass")
            let q = Self.oneLine(pattern, 60)
            if showExplorer && frames[.explorer] != nil {
                await move(to: searchPoint, style: .ibeam)
                await click()
                searchText = ""
                var typed = ""
                for ch in q { if cancelled { break }; typed.append(ch); searchText = typed; await wait(0.03) }
                await wait(0.8)
                searchText = nil
            } else {
                await move(to: quickOpenPoint, style: .arrow)
                quickOpen = ""
                var typed = ""
                for ch in q { if cancelled { break }; typed.append(ch); quickOpen = typed; await wait(0.03) }
                await wait(0.7)
                quickOpen = nil
            }
        } else {
            setCaption(e.title, icon: "wrench.and.screwdriver")
            await wait(0.9)
        }
    }

    // History before the replay window lands instantly.

    private func prime(_ evs: [TimelineEvent]) {
        if let p = evs.last(where: { $0.kind == "agent.plan" }) { plan = Self.planSteps(p) }
        if let m = evs.last(where: { $0.kind == "agent.message" }) {
            thought = Self.plainText(m.detail?["text"]?.string ?? m.title, 560)
            thoughtDone = true
        }
        for e in evs.filter({ $0.kind.hasPrefix("agent.command") || $0.kind == "agent.test" }).suffix(5) {
            let cmd = e.detail?["command"]?.string ?? ""
            if e.kind == "agent.command" || e.kind == "agent.test" || cmd != lastCommand {
                appendTerm(prompt + Self.oneLine(cmd, 260), .command)
                lastCommand = cmd
            }
            if let out = e.detail?["output"]?.string {
                for l in out.components(separatedBy: "\n").map(Self.stripAnsi).filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).suffix(3) {
                    appendTerm(String(l.prefix(300)), .output)
                }
                let ok = e.kind != "agent.command_failed" && (e.detail?["ok"]?.bool ?? true)
                appendTerm(ok ? "✓ done" : "✗ failed", ok ? .ok : .fail)
            }
        }
        ticker = Array(evs.filter(Self.isScene).suffix(5))
    }
}
