import SwiftUI
import Observation

/// What a workspace panel shows. Files, agents, search and Git changes live
/// in the navigator beside the panels; Remote Desktop floats above them
/// (DesktopStore), so it stays visible whatever the panels are doing.
enum PanelKind: String, Codable, CaseIterable, Identifiable {
    case editor, terminal, agent, visualiser, preview, builds
    var id: String { rawValue }
    var title: String {
        switch self {
        case .editor: return "Editor"; case .terminal: return "Terminal"; case .agent: return "Agent"
        case .visualiser: return "Visualiser"; case .preview: return "Web Preview"; case .builds: return "Builds & Tests"
        }
    }
    var icon: String {
        switch self {
        case .editor: return "chevron.left.forwardslash.chevron.right"; case .terminal: return "terminal"; case .agent: return "sparkles"
        case .visualiser: return "chart.xyaxis.line"; case .preview: return "safari"; case .builds: return "hammer"
        }
    }
    /// ⌃⌘ shortcut letter to show or focus a panel of this kind.
    var key: Character { switch self { case .editor: return "e"; case .terminal: return "t"; case .agent: return "a"; case .visualiser: return "v"; case .preview: return "w"; case .builds: return "b" } }
}

struct PanelSlot: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: PanelKind
    var config: [String: String] = [:]
}

struct LayoutColumn: Codable, Identifiable, Equatable {
    var id = UUID()
    var width: CGFloat
    var panels: [PanelSlot]
    var heights: [CGFloat]
}

struct WorkspaceLayout: Codable, Equatable {
    var columns: [LayoutColumn]
    var maximized: UUID?
    var minimized: [PanelSlot] = []   // panels folded into the status bar, restorable

    enum Preset: String, CaseIterable, Identifiable {
        case code, agent, visual, review
        var id: String { rawValue }
        var title: String { switch self { case .code: return "Code"; case .agent: return "Agent"; case .visual: return "Visualise"; case .review: return "Review" } }
        var icon: String { switch self { case .code: return "chevron.left.forwardslash.chevron.right"; case .agent: return "sparkles"; case .visual: return "chart.xyaxis.line"; case .review: return "checklist" } }
    }

    static func preset(_ p: Preset, portrait: Bool) -> WorkspaceLayout {
        func col(_ w: CGFloat, _ items: [(PanelKind, CGFloat)]) -> LayoutColumn {
            LayoutColumn(width: w, panels: items.map { PanelSlot(kind: $0.0) }, heights: items.map(\.1))
        }
        if portrait {
            switch p {
            case .code: return WorkspaceLayout(columns: [col(1, [(.editor, 0.64), (.terminal, 0.36)])])
            case .agent: return WorkspaceLayout(columns: [col(1, [(.agent, 0.56), (.editor, 0.44)])])
            case .visual: return WorkspaceLayout(columns: [col(1, [(.visualiser, 0.55), (.agent, 0.45)])])
            case .review: return WorkspaceLayout(columns: [col(1, [(.editor, 0.62), (.builds, 0.38)])])
            }
        }
        switch p {
        case .code: return WorkspaceLayout(columns: [col(0.62, [(.editor, 0.66), (.terminal, 0.34)]), col(0.38, [(.agent, 1)])])
        case .agent: return WorkspaceLayout(columns: [col(0.5, [(.agent, 1)]), col(0.5, [(.editor, 0.62), (.terminal, 0.38)])])
        case .visual: return WorkspaceLayout(columns: [col(0.42, [(.agent, 1)]), col(0.58, [(.visualiser, 0.7), (.terminal, 0.3)])])
        case .review: return WorkspaceLayout(columns: [col(0.64, [(.editor, 0.7), (.builds, 0.3)]), col(0.36, [(.agent, 1)])])
        }
    }
    static func standard(portrait: Bool) -> WorkspaceLayout { preset(.agent, portrait: portrait) }

    var slots: [PanelSlot] { columns.flatMap(\.panels) }

    mutating func normalise() {
        columns.removeAll { $0.panels.isEmpty }
        let tw = columns.reduce(0) { $0 + $1.width }
        for i in columns.indices {
            columns[i].width = tw > 0 ? columns[i].width / tw : 1 / CGFloat(columns.count)
            if columns[i].heights.count != columns[i].panels.count { columns[i].heights = Array(repeating: 1 / CGFloat(columns[i].panels.count), count: columns[i].panels.count) }
            let th = columns[i].heights.reduce(0, +)
            columns[i].heights = columns[i].heights.map { th > 0 ? $0 / th : 1 / CGFloat(columns[i].panels.count) }
        }
        if let m = maximized, !columns.contains(where: { $0.panels.contains { $0.id == m } }) { maximized = nil }
    }

    func locate(_ id: UUID) -> (Int, Int)? {
        for (c, col) in columns.enumerated() { if let r = col.panels.firstIndex(where: { $0.id == id }) { return (c, r) } }
        return nil
    }
}

enum WorkspaceLayoutStore {
    // v2: the unified workspace's panel kinds (older layouts used other kinds).
    static func key(_ project: String, portrait: Bool) -> String { "ws2.layout.\(project)\(portrait ? ".portrait" : "")" }
    static func load(_ project: String, portrait: Bool) -> WorkspaceLayout {
        if let d = UserDefaults.standard.data(forKey: key(project, portrait: portrait)),
           let l = try? JSONDecoder().decode(WorkspaceLayout.self, from: d), !l.columns.isEmpty {
            return l
        }
        return .standard(portrait: portrait)
    }
    static func save(_ l: WorkspaceLayout, _ project: String, portrait: Bool) {
        if let d = try? JSONEncoder().encode(l) { UserDefaults.standard.set(d, forKey: key(project, portrait: portrait)) }
    }
    static func resetAll() {
        for k in UserDefaults.standard.dictionaryRepresentation().keys where k.hasPrefix("ws2.layout.") || k.hasPrefix("layout.") { UserDefaults.standard.removeObject(forKey: k) }
    }
}

enum NavigatorTab: String, CaseIterable, Identifiable {
    case files, agents, git
    var id: String { rawValue }
    var title: String { switch self { case .files: return "Files"; case .agents: return "Agents"; case .git: return "Source Control" } }
    var icon: String { switch self { case .files: return "folder"; case .agents: return "sparkles"; case .git: return "arrow.triangle.branch" } }
}

/// The one workspace: the open project, its panel layout (saved per project
/// and orientation), the navigator and which panel has focus. App actions
/// ("open this file", "show this agent", "attach to that tmux session") go
/// through `reveal`, which reuses a panel of the right kind before adding one.
@MainActor
@Observable
final class WorkspaceStore {
    private(set) var projectId: String?
    var layout = WorkspaceLayout.standard(portrait: false) { didSet { save() } }
    private(set) var portrait = false
    var focused: UUID?
    var navigator: NavigatorTab = NavigatorTab(rawValue: UserDefaults.standard.string(forKey: "ws.navigator") ?? "") ?? .files {
        didSet { UserDefaults.standard.set(navigator.rawValue, forKey: "ws.navigator") }
    }
    var navigatorVisible: Bool = UserDefaults.standard.object(forKey: "ws.navigatorVisible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(navigatorVisible, forKey: "ws.navigatorVisible") }
    }
    var navigatorWidth: CGFloat = CGFloat(UserDefaults.standard.object(forKey: "ws.navigatorWidth") as? Double ?? 264) {
        didSet { UserDefaults.standard.set(Double(navigatorWidth), forKey: "ws.navigatorWidth") }
    }
    /// Phone and narrow windows show one panel at a time.
    var page: UUID?
    private var loading = false

    init() {
        projectId = UserDefaults.standard.string(forKey: "workspaceProject")
        reload()
    }

    func open(project id: String?) {
        guard id != projectId else { return }
        projectId = id
        UserDefaults.standard.set(id, forKey: "workspaceProject")
        reload()
    }

    func setPortrait(_ p: Bool) {
        guard p != portrait else { return }
        portrait = p
        reload()
    }

    private func reload() {
        loading = true
        layout = projectId.map { WorkspaceLayoutStore.load($0, portrait: portrait) } ?? .standard(portrait: portrait)
        loading = false
        if let f = focused, layout.locate(f) == nil { focused = nil }
    }

    private func save() {
        guard !loading, let p = projectId else { return }
        WorkspaceLayoutStore.save(layout, p, portrait: portrait)
    }

    func apply(_ preset: WorkspaceLayout.Preset) {
        var l = WorkspaceLayout.preset(preset, portrait: portrait)
        l.normalise()
        layout = l
        focused = layout.slots.first?.id
    }

    // MARK: panel operations

    @discardableResult
    func add(_ k: PanelKind, config: [String: String] = [:], beside id: UUID? = nil) -> UUID {
        let slot = PanelSlot(kind: k, config: config)
        if let id, case let (c, r)? = layout.locate(id) {
            // Split the given panel's column below it.
            let h = layout.columns[c].heights[r] / 2
            layout.columns[c].heights[r] = h
            layout.columns[c].panels.insert(slot, at: r + 1); layout.columns[c].heights.insert(h, at: r + 1)
        } else if layout.columns.count < 3 && !portrait {
            layout.columns.append(LayoutColumn(width: 0.3, panels: [slot], heights: [1]))
        } else if let i = layout.columns.indices.min(by: { layout.columns[$0].panels.count < layout.columns[$1].panels.count }) {
            layout.columns[i].panels.append(slot); layout.columns[i].heights.append(1 / CGFloat(layout.columns[i].panels.count))
        } else {
            layout.columns = [LayoutColumn(width: 1, panels: [slot], heights: [1])]
        }
        layout.maximized = nil
        layout.normalise()
        focused = slot.id; page = slot.id
        return slot.id
    }

    /// Show `kind` (configured) in an existing panel of that kind when there
    /// is one, else add it. Restores a minimised one first.
    @discardableResult
    func reveal(_ k: PanelKind, config: [String: String] = [:], match: ((PanelSlot) -> Bool)? = nil) -> UUID {
        if let i = layout.minimized.firstIndex(where: { $0.kind == k && (match?($0) ?? true) }) {
            let slot = layout.minimized.remove(at: i)
            let id = add(slot.kind, config: slot.config.merging(config) { $1 })
            return id
        }
        let candidates = layout.slots.filter { $0.kind == k }
        if let s = candidates.first(where: { match?($0) ?? false }) ?? (match == nil ? candidates.first(where: { $0.id == focused }) ?? candidates.first : nil) {
            if !config.isEmpty, case let (c, r)? = layout.locate(s.id) { layout.columns[c].panels[r].config.merge(config) { $1 } }
            if layout.maximized != nil && layout.maximized != s.id { layout.maximized = nil }
            focused = s.id; page = s.id
            return s.id
        }
        return add(k, config: config)
    }

    func close(_ id: UUID) {
        guard case let (c, r)? = layout.locate(id) else { return }
        layout.columns[c].panels.remove(at: r); layout.columns[c].heights.remove(at: r)
        if layout.columns.allSatisfy({ $0.panels.isEmpty }) { layout.columns = [] }
        layout.normalise()
        if focused == id { focused = layout.slots.first?.id }
        if page == id { page = layout.slots.first?.id }
    }

    func minimize(_ id: UUID) {
        guard case let (c, r)? = layout.locate(id) else { return }
        let slot = layout.columns[c].panels[r]
        close(id)
        layout.minimized.append(slot)
    }

    func restore(_ id: UUID) {
        guard let i = layout.minimized.firstIndex(where: { $0.id == id }) else { return }
        let slot = layout.minimized.remove(at: i)
        _ = add(slot.kind, config: slot.config)
    }

    func toggleMaximize(_ id: UUID) {
        layout.maximized = layout.maximized == id ? nil : id
        focused = id
    }

    func replace(_ id: UUID, with k: PanelKind) {
        guard case let (c, r)? = layout.locate(id) else { return }
        layout.columns[c].panels[r] = PanelSlot(id: id, kind: k)
    }

    func setConfig(_ id: UUID, _ key: String, _ value: String?) {
        guard case let (c, r)? = layout.locate(id), layout.columns[c].panels[r].config[key] != value else { return }
        layout.columns[c].panels[r].config[key] = value
    }

    func move(_ id: UUID, dc: Int, dr: Int) {
        guard case let (c, r)? = layout.locate(id) else { return }
        let slot = layout.columns[c].panels[r]
        if dr != 0 {
            let to = r + dr
            guard to >= 0, to < layout.columns[c].panels.count else { return }
            layout.columns[c].panels.swapAt(r, to); layout.columns[c].heights.swapAt(r, to)
            return
        }
        layout.columns[c].panels.remove(at: r); layout.columns[c].heights.remove(at: r)
        let target = c + dc
        if target < 0 { layout.columns.insert(LayoutColumn(width: 0.3, panels: [slot], heights: [1]), at: 0) }
        else if target >= layout.columns.count { layout.columns.append(LayoutColumn(width: 0.3, panels: [slot], heights: [1])) }
        else { layout.columns[target].panels.append(slot); layout.columns[target].heights.append(1 / CGFloat(layout.columns[target].panels.count)) }
        layout.normalise()
    }

    /// Drop a panel onto another: before/after it in that column, or into a
    /// new column on its left/right.
    enum Drop { case above, below, left, right }
    func drop(_ id: UUID, on target: UUID, _ where_: Drop) {
        guard id != target, case let (c, r)? = layout.locate(id) else { return }
        let slot = layout.columns[c].panels[r]
        layout.columns[c].panels.remove(at: r); layout.columns[c].heights.remove(at: r)
        layout.normalise()
        guard case let (tc, tr)? = layout.locate(target) else { layout.columns.append(LayoutColumn(width: 0.3, panels: [slot], heights: [1])); layout.normalise(); return }
        switch where_ {
        case .above, .below:
            let at = where_ == .above ? tr : tr + 1
            let h = layout.columns[tc].heights[tr] / 2
            layout.columns[tc].heights[tr] = h
            layout.columns[tc].panels.insert(slot, at: at); layout.columns[tc].heights.insert(h, at: at)
        case .left, .right:
            let w = layout.columns[tc].width / 2
            layout.columns[tc].width = w
            layout.columns.insert(LayoutColumn(width: w, panels: [slot], heights: [1]), at: where_ == .left ? tc : tc + 1)
        }
        layout.normalise()
        focused = slot.id
    }

    func resizeColumn(_ c: Int, _ delta: CGFloat) {
        guard c + 1 < layout.columns.count else { return }
        let a = layout.columns[c].width + delta, b = layout.columns[c + 1].width - delta
        guard a > 0.14, b > 0.14 else { return }
        layout.columns[c].width = a; layout.columns[c + 1].width = b
    }

    func resizeRow(_ c: Int, _ r: Int, _ delta: CGFloat) {
        guard c < layout.columns.count, r + 1 < layout.columns[c].heights.count else { return }
        let a = layout.columns[c].heights[r] + delta, b = layout.columns[c].heights[r + 1] - delta
        guard a > 0.1, b > 0.1 else { return }
        layout.columns[c].heights[r] = a; layout.columns[c].heights[r + 1] = b
    }

    func focus(index n: Int) {
        let s = layout.slots
        guard n >= 0, n < s.count else { return }
        focused = s[n].id; page = s[n].id
    }

    func cycleFocus(_ step: Int) {
        let s = layout.slots
        guard !s.isEmpty else { return }
        let i = s.firstIndex { $0.id == focused } ?? 0
        let n = (i + step + s.count) % s.count
        focused = s[n].id; page = s[n].id
    }
}

extension Array {
    subscript(safe i: Int, default d: Element) -> Element { indices.contains(i) ? self[i] : d }
}
