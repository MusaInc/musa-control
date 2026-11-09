import SwiftUI

// Smart windows for the studio. The board is a pure value: which windows
// exist, which one the agent's newest important action belongs to, which
// ones the user pinned or popped out. Layout is a pure function of the
// board and the stage size, so it's unit-tested and animates as one diff.

enum PaneKind: String, CaseIterable, Identifiable, Equatable {
    case editor, terminal, explorer, thought, plan, tests, runs, diff, lightbox, files
    var id: String { rawValue }

    var title: String {
        switch self {
        case .editor: return "Editor"
        case .terminal: return "Terminal"
        case .explorer: return "Explorer"
        case .thought: return "Thinking"
        case .plan: return "Plan"
        case .tests: return "Tests"
        case .runs: return "Runs"
        case .diff: return "Diff"
        case .lightbox: return "Screenshots"
        case .files: return "Files touched"
        }
    }
    var icon: String {
        switch self {
        case .editor: return "doc.text"
        case .terminal: return "terminal"
        case .explorer: return "folder"
        case .thought: return "brain"
        case .plan: return "list.bullet"
        case .tests: return "checklist"
        case .runs: return "timer"
        case .diff: return "arrow.left.arrow.right"
        case .lightbox: return "photo"
        case .files: return "square.grid.3x3.fill"
        }
    }
    var region: StudioDirector.Region {
        switch self {
        case .editor: return .editor
        case .terminal: return .terminal
        case .explorer: return .explorer
        case .thought: return .thought
        case .plan: return .plan
        case .tests: return .tests
        case .runs: return .runs
        case .diff: return .diff
        case .lightbox: return .lightbox
        case .files: return .files
        }
    }
}

struct Pane: Equatable {
    var open = false          // spawned by something the agent did (or the user)
    var touched = 0           // recency stamp
    var minimized = false     // the user sent it to the dock
    var pinned: Int?          // slot it's pinned to
    var floating: CGRect?     // popped out: free frame in stage space
}

struct BoardLayout: Equatable {
    var frames: [PaneKind: CGRect] = [:]   // every visible window (tiled and floating)
    var primary: PaneKind?
    var tiled: [PaneKind] = []             // in slot order
    var floating: [PaneKind] = []
    var docked: [PaneKind] = []            // open, but minimised into the dock
}

struct WindowBoard: Equatable {
    var panes: [PaneKind: Pane] = [:]
    var focus: PaneKind?
    var clock = 0

    static let dockHeight: CGFloat = 44

    /// What a fresh studio shows before the agent does anything.
    static var initial: WindowBoard {
        var b = WindowBoard()
        for k in [PaneKind.thought, .explorer, .terminal] { b.spawn(k, focus: false) }
        b.spawn(.editor, focus: true)
        return b
    }

    func pane(_ k: PaneKind) -> Pane { panes[k] ?? Pane() }
    func isOpen(_ k: PaneKind) -> Bool { pane(k).open }

    /// The agent did something that belongs in `k`: open it, mark it recent,
    /// and (unless the user is steering) make it the focus.
    mutating func spawn(_ k: PaneKind, focus takeFocus: Bool) {
        clock += 1
        var p = pane(k)
        p.open = true
        p.touched = clock
        if takeFocus { p.minimized = false; focus = k }
        panes[k] = p
    }

    // User actions.
    mutating func bringForward(_ k: PaneKind) { spawn(k, focus: true) }
    mutating func minimize(_ k: PaneKind) {
        var p = pane(k)
        p.minimized = true; p.pinned = nil; p.floating = nil
        panes[k] = p
        if focus == k { focus = nil }
    }
    mutating func close(_ k: PaneKind) {
        panes[k] = Pane()
        if focus == k { focus = nil }
    }
    mutating func togglePin(_ k: PaneKind, slot: Int?) {
        var p = pane(k)
        p.pinned = p.pinned == nil ? (slot ?? 0) : nil
        panes[k] = p
    }
    mutating func float(_ k: PaneKind, frame: CGRect) {
        var p = pane(k)
        p.open = true; p.minimized = false; p.pinned = nil; p.floating = frame
        clock += 1; p.touched = clock
        panes[k] = p
    }
    mutating func dock(_ k: PaneKind) {
        var p = pane(k)
        p.floating = nil
        panes[k] = p
    }

    // MARK: Layout

    static func capacity(_ s: CGSize) -> Int {
        if s.width >= 980 { return 4 }
        if s.width >= 640 { return s.height >= 520 ? 3 : 2 }
        return s.height >= 460 ? 2 : 1
    }

    /// Slot rectangles for `n` windows: the first is the primary.
    static func slots(_ n: Int, in s: CGSize, gap: CGFloat = 12) -> [CGRect] {
        guard n > 0, s.width > 0, s.height > 0 else { return [] }
        if n == 1 { return [CGRect(origin: .zero, size: s)] }
        let wide = s.width >= 980 || (s.width >= 640 && s.width >= s.height * 1.15)
        var out: [CGRect] = []
        let side = n - 1
        if wide {
            let pw = (s.width - gap) * (n == 2 ? 0.58 : 0.62)
            out.append(CGRect(x: 0, y: 0, width: pw, height: s.height))
            let x = pw + gap, w = s.width - x
            let h = (s.height - gap * CGFloat(side - 1)) / CGFloat(side)
            for i in 0..<side { out.append(CGRect(x: x, y: CGFloat(i) * (h + gap), width: w, height: h)) }
        } else {
            let ph = (s.height - gap) * 0.6
            out.append(CGRect(x: 0, y: 0, width: s.width, height: ph))
            let y = ph + gap, h = s.height - y
            let w = (s.width - gap * CGFloat(side - 1)) / CGFloat(side)
            for i in 0..<side { out.append(CGRect(x: CGFloat(i) * (w + gap), y: y, width: w, height: h)) }
        }
        return out
    }

    func layout(in size: CGSize) -> BoardLayout {
        var out = BoardLayout()
        let openKinds = PaneKind.allCases.filter { pane($0).open }
        out.floating = openKinds.filter { pane($0).floating != nil && !pane($0).minimized }
            .sorted { pane($0).touched < pane($1).touched }
        let candidates = openKinds.filter { pane($0).floating == nil && !pane($0).minimized }
        let hasDock = openKinds.contains { pane($0).minimized } || candidates.count > Self.capacity(size)
        var area = size
        if hasDock { area.height = max(0, area.height - Self.dockHeight - 8) }
        let cap = Self.capacity(area)

        // Who gets a slot: pinned first, then the focus, then the most recent.
        var chosen: [PaneKind] = candidates.filter { pane($0).pinned != nil }.sorted { pane($0).pinned! < pane($1).pinned! }
        if chosen.count > cap { chosen = Array(chosen.prefix(cap)) }
        if let f = focus, candidates.contains(f), !chosen.contains(f), chosen.count < cap { chosen.append(f) }
        for k in candidates.sorted(by: { pane($0).touched > pane($1).touched }) where chosen.count < cap && !chosen.contains(k) {
            chosen.append(k)
        }

        // Which slot each one takes: pinned keep theirs, the focus takes the
        // primary if it's free, the rest fill in by recency.
        let slots = Self.slots(chosen.count, in: area)
        var bySlot = [PaneKind?](repeating: nil, count: slots.count)
        for k in chosen where pane(k).pinned != nil {
            var i = min(pane(k).pinned!, slots.count - 1)
            while bySlot[i] != nil { i = (i + 1) % slots.count }
            bySlot[i] = k
        }
        if let f = focus, chosen.contains(f), pane(f).pinned == nil, let i = bySlot.firstIndex(where: { $0 == nil }) { bySlot[i] = f }
        for k in chosen.sorted(by: { pane($0).touched > pane($1).touched }) where !bySlot.contains(k) {
            if let i = bySlot.firstIndex(where: { $0 == nil }) { bySlot[i] = k }
        }
        for (i, k) in bySlot.enumerated() {
            guard let k else { continue }
            out.frames[k] = slots[i]
            out.tiled.append(k)
        }
        out.primary = bySlot.first ?? nil
        for k in out.floating { out.frames[k] = clamp(pane(k).floating!, in: size) }
        out.docked = openKinds.filter { out.frames[$0] == nil }.sorted { pane($0).touched > pane($1).touched }
        return out
    }

    /// Keeps a floating window reachable on the stage.
    func clamp(_ r: CGRect, in s: CGSize) -> CGRect {
        let w = min(max(220, r.width), s.width), h = min(max(140, r.height), s.height)
        let x = min(max(0, r.minX), s.width - w), y = min(max(0, r.minY), s.height - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Which slot a window is in right now (for pinning it there).
    func slot(of k: PaneKind, in size: CGSize) -> Int? { layout(in: size).tiled.firstIndex(of: k) }
}

/// Event → window. Each kind of real event belongs to one window (and
/// sometimes a supporting one); this is the generative-UI mapping.
enum WindowRules {
    struct Route: Equatable { let focus: PaneKind?; let also: [PaneKind] }

    static func route(_ e: TimelineEvent, testResult: Bool) -> Route {
        switch e.kind {
        case "agent.read": return Route(focus: .editor, also: [.files])
        case "agent.edit": return Route(focus: .editor, also: [.diff, .files])
        case "agent.command":
            return Route(focus: .terminal, also: [.runs])
        case "agent.test":
            return Route(focus: testResult ? .tests : .terminal, also: [.runs, .tests])
        case "agent.command_done", "agent.command_failed":
            return Route(focus: testResult ? .tests : .terminal, also: testResult ? [.runs, .terminal] : [.runs])
        case "agent.message", "agent.prompt": return Route(focus: .thought, also: [])
        case "agent.plan": return Route(focus: nil, also: [.plan])
        case "agent.image": return Route(focus: .lightbox, also: [])
        case "agent.tool": return Route(focus: nil, also: [.explorer])
        default: return Route(focus: nil, also: [])
        }
    }
}
