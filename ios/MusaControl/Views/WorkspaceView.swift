import SwiftUI

enum PanelKind: String, Codable, CaseIterable, Identifiable {
    case files, editor, agents, follow, terminal, preview, screenshots, git, builds, timeline, desktop
    var id: String { rawValue }
    var title: String {
        switch self {
        case .files: return "Files"; case .editor: return "Editor"; case .agents: return "Agents"; case .follow: return "Follow Agent"
        case .terminal: return "Terminal"; case .preview: return "Preview"; case .screenshots: return "Screenshots"; case .git: return "Git"
        case .builds: return "Builds & Tests"; case .timeline: return "Timeline"; case .desktop: return "Remote Desktop"
        }
    }
    var icon: String {
        switch self {
        case .files: return "folder"; case .editor: return "doc.text"; case .agents: return "sparkles"; case .follow: return "scope"
        case .terminal: return "terminal"; case .preview: return "safari"; case .screenshots: return "photo.on.rectangle"; case .git: return "arrow.triangle.branch"
        case .builds: return "hammer"; case .timeline: return "clock.arrow.circlepath"; case .desktop: return "display"
        }
    }
}

struct PanelSlot: Codable, Identifiable, Equatable { var id = UUID(); var kind: PanelKind; var config: [String: String] = [:] }
struct LayoutColumn: Codable, Identifiable, Equatable { var id = UUID(); var width: CGFloat; var panels: [PanelSlot]; var heights: [CGFloat] }
struct WorkspaceLayout: Codable, Equatable {
    var columns: [LayoutColumn]
    var maximized: UUID?

    static func standard() -> WorkspaceLayout {
        WorkspaceLayout(columns: [
            LayoutColumn(width: 0.2, panels: [PanelSlot(kind: .files)], heights: [1]),
            LayoutColumn(width: 0.44, panels: [PanelSlot(kind: .editor), PanelSlot(kind: .agents)], heights: [0.58, 0.42]),
            LayoutColumn(width: 0.36, panels: [PanelSlot(kind: .follow), PanelSlot(kind: .terminal)], heights: [0.56, 0.44]),
        ], maximized: nil)
    }
    static func portrait() -> WorkspaceLayout {
        WorkspaceLayout(columns: [
            LayoutColumn(width: 1, panels: [PanelSlot(kind: .follow), PanelSlot(kind: .agents), PanelSlot(kind: .terminal)], heights: [0.42, 0.33, 0.25]),
        ], maximized: nil)
    }

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
    static func key(_ project: String, portrait: Bool) -> String { "layout.\(project)\(portrait ? ".portrait" : "")" }
    static func load(_ project: String, portrait: Bool) -> WorkspaceLayout {
        if let d = UserDefaults.standard.data(forKey: key(project, portrait: portrait)), let l = try? JSONDecoder().decode(WorkspaceLayout.self, from: d) { return l }
        return portrait ? .portrait() : .standard()
    }
    static func save(_ l: WorkspaceLayout, _ project: String, portrait: Bool) {
        if let d = try? JSONEncoder().encode(l) { UserDefaults.standard.set(d, forKey: key(project, portrait: portrait)) }
    }
    static func resetAll() {
        for k in UserDefaults.standard.dictionaryRepresentation().keys where k.hasPrefix("layout.") { UserDefaults.standard.removeObject(forKey: k) }
    }
}

struct WorkspacesView: View {
    @Environment(AppModel.self) private var app
    @State private var recent: [String] = UserDefaults.standard.stringArray(forKey: "workspaces.recent") ?? []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(recent, id: \.self) { id in
                            if let p = app.project(id) {
                                HStack(spacing: 6) {
                                    Image(systemName: p.icon).font(.system(size: 12))
                                    Text(p.name).font(.system(size: 13.5, weight: app.workspaceProject == id ? .semibold : .regular)).lineLimit(1)
                                    if (p.activeAgents ?? 0) > 0 { StatusDot(status: "working", size: 6) }
                                    Button { recent.removeAll { $0 == id }; save(); if app.workspaceProject == id { app.workspaceProject = recent.first } } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 16, height: 16) }.buttonStyle(.plain).foregroundStyle(Theme.textFaint)
                                }
                                .padding(.leading, 10).padding(.trailing, 4).frame(height: 30)
                                .background(app.workspaceProject == id ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                                .onTapGesture { app.openWorkspace(id) }
                            }
                        }
                    }.padding(4)
                }
                Menu {
                    ForEach(app.projects) { p in Button { app.openWorkspace(p.id) } label: { Label(p.name, systemImage: p.icon) } }
                } label: { Image(systemName: "plus").frame(width: 32, height: 32) }
                .accessibilityIdentifier("workspace.open")
            }
            .padding(.trailing, 6).background(Theme.bg)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
            if let id = app.workspaceProject, app.project(id) != nil {
                WorkspaceView(projectId: id).id(id)
            } else {
                ProjectGrid()
            }
        }
        .background(Theme.bg)
        .onChange(of: app.workspaceProject) { _, id in
            guard let id else { return }
            recent.removeAll { $0 == id }; recent.insert(id, at: 0); recent = Array(recent.prefix(8)); save()
        }
        .onAppear { if let id = app.workspaceProject, !recent.contains(id) { recent.insert(id, at: 0); save() } }
    }
    func save() { UserDefaults.standard.set(recent, forKey: "workspaces.recent") }
}

struct ProjectGrid: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Open a workspace").font(.system(size: 20, weight: .semibold))
                Text("Each project keeps its own layout, files, agents and terminals.").font(Theme.caption).foregroundStyle(Theme.textDim)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 10)], spacing: 10) {
                    ForEach(app.projects) { p in
                        Button { app.openWorkspace(p.id) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: p.icon).font(.system(size: 15)).frame(width: 32, height: 32).background(Theme.hover, in: RoundedRectangle(cornerRadius: 8)).foregroundStyle(Theme.accent)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(p.name).font(.system(size: 14.5, weight: .semibold)).lineLimit(1)
                                    Text(p.path.replacingOccurrences(of: #"^/(home|Users)/[^/]+"#, with: "~", options: .regularExpression)).font(.system(size: 12)).foregroundStyle(Theme.textFaint).lineLimit(1).truncationMode(.middle)
                                    HStack(spacing: 6) {
                                        Pill(text: p.kind)
                                        if p.github != nil { Pill(text: "GitHub", color: Theme.blue) }
                                        if let n = p.activeAgents, n > 0 { Pill(text: "\(n) agent\(n == 1 ? "" : "s")", color: Theme.green) }
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .card()
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("project.\(p.id)")
                    }
                }
            }
            .padding(16)
        }
    }
}

struct WorkspaceView: View {
    let projectId: String
    @Environment(AppModel.self) private var app
    @State private var layout = WorkspaceLayout.standard()
    @State private var portrait = false
    @State private var loaded = false
    @State private var page: UUID?
    @Environment(\.compactLayout) private var compact

    var body: some View {
        GeometryReader { geo in
            let isPortrait = geo.size.width < 820
            VStack(spacing: 0) {
                toolbar
                Group {
                    if compact {
                        paged
                    } else if let m = layout.maximized, let loc = layout.locate(m) {
                        panel(layout.columns[loc.0].panels[loc.1], column: loc.0, row: loc.1)
                    } else {
                        columns(size: CGSize(width: geo.size.width, height: geo.size.height - 44))
                    }
                }
            }
            .onAppear { portrait = isPortrait; layout = WorkspaceLayoutStore.load(projectId, portrait: isPortrait); loaded = true }
            .onChange(of: isPortrait) { _, p in portrait = p; layout = WorkspaceLayoutStore.load(projectId, portrait: p) }
            .onChange(of: layout) { _, l in if loaded { WorkspaceLayoutStore.save(l, projectId, portrait: portrait) } }
        }
        .background(Theme.line)
    }

    /// Phone: one panel at a time, chosen from a strip of the layout's panels.
    var paged: some View {
        let slots = layout.columns.flatMap(\.panels)
        let current = slots.first { $0.id == page } ?? slots.first
        return VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(slots) { slot in
                        let on = slot.id == current?.id
                        Button { page = slot.id } label: {
                            Label(slot.kind.title, systemImage: slot.kind.icon).font(.system(size: 13, weight: on ? .semibold : .regular))
                                .padding(.horizontal, 11).frame(height: 30)
                                .background(on ? Theme.accent.opacity(0.18) : Theme.hover, in: Capsule())
                                .foregroundStyle(on ? Theme.accent : Theme.textDim)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            ForEach(PanelKind.allCases) { k in Button { if let loc = layout.locate(slot.id) { replace(slot.id, with: k); page = layout.columns[loc.0].panels[loc.1].id } } label: { Label("Show \(k.title)", systemImage: k.icon) } }
                            Divider()
                            Button(role: .destructive) { close(slot.id); page = nil } label: { Label("Close panel", systemImage: "xmark") }
                        }
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
            .background(Theme.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
            if let slot = current {
                PanelContent(slot: slot, projectId: projectId, setConfig: { k, v in setConfig(slot.id, k, v) })
                    .id(slot.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.surface)
            }
        }
    }

    var toolbar: some View {
        HStack(spacing: 8) {
            if let p = app.project(projectId) {
                Text(p.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                if !compact { Text(p.path.replacingOccurrences(of: #"^/(home|Users)/[^/]+"#, with: "~", options: .regularExpression)).font(Theme.caption).foregroundStyle(Theme.textFaint).lineLimit(1) }
            }
            Spacer()
            Button { app.launcherProject = projectId; app.showLauncher = true } label: { Label("Agent", systemImage: "plus").font(Theme.label) }
            Menu {
                ForEach(PanelKind.allCases) { k in Button { add(k) } label: { Label(k.title, systemImage: k.icon) } }
                Divider()
                Button { layout = portrait ? .portrait() : .standard() } label: { Label("Reset layout", systemImage: "arrow.counterclockwise") }
            } label: { Label("Panel", systemImage: "rectangle.badge.plus").font(Theme.label) }
            .accessibilityIdentifier("workspace.addPanel")
        }
        .padding(.horizontal, 14).frame(height: 44).background(Theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    func columns(size: CGSize) -> some View {
        let dividers = CGFloat(max(layout.columns.count - 1, 0)) * 1
        let usable = size.width - dividers
        return HStack(spacing: 0) {
            ForEach(Array(layout.columns.enumerated()), id: \.element.id) { c, col in
                let w = usable * col.width
                VStack(spacing: 0) {
                    let rowUsable = size.height - CGFloat(max(col.panels.count - 1, 0))
                    ForEach(Array(col.panels.enumerated()), id: \.element.id) { r, slot in
                        panel(slot, column: c, row: r).frame(height: max(80, rowUsable * col.heights[safe: r, default: 1 / CGFloat(col.panels.count)]))
                        if r < col.panels.count - 1 { RowDivider { dy in resizeRow(c, r, dy / max(rowUsable, 1)) } }
                    }
                }
                .frame(width: max(220, w))
                if c < layout.columns.count - 1 { ColumnDivider { dx in resizeColumn(c, dx / max(usable, 1)) } }
            }
        }
    }

    @ViewBuilder func panel(_ slot: PanelSlot, column c: Int, row r: Int) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Menu {
                    ForEach(PanelKind.allCases) { k in Button { replace(slot.id, with: k) } label: { Label(k.title, systemImage: k.icon) } }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: slot.kind.icon).font(.system(size: 12, weight: .semibold))
                        Text(slot.kind.title).font(.system(size: 12.5, weight: .semibold))
                        Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).foregroundStyle(Theme.textFaint)
                    }.foregroundStyle(Theme.textDim)
                }
                Spacer()
                Menu {
                    Button { move(slot.id, dc: -1, dr: 0) } label: { Label("Move left", systemImage: "arrow.left") }.disabled(c == 0 && layout.columns[c].panels.count == 1)
                    Button { move(slot.id, dc: 1, dr: 0) } label: { Label("Move right", systemImage: "arrow.right") }
                    Button { move(slot.id, dc: 0, dr: -1) } label: { Label("Move up", systemImage: "arrow.up") }.disabled(r == 0)
                    Button { move(slot.id, dc: 0, dr: 1) } label: { Label("Move down", systemImage: "arrow.down") }.disabled(r == layout.columns[c].panels.count - 1)
                    Button { split(slot.id) } label: { Label("Split below", systemImage: "rectangle.split.1x2") }
                } label: { Image(systemName: "rectangle.3.group").font(.system(size: 12)).frame(width: 26, height: 26) }
                IconButton(systemName: layout.maximized == slot.id ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", help: layout.maximized == slot.id ? "Restore" : "Maximise") {
                    withAnimation(.easeInOut(duration: 0.2)) { layout.maximized = layout.maximized == slot.id ? nil : slot.id }
                }
                IconButton(systemName: "xmark", help: "Close panel") { close(slot.id) }
            }
            .padding(.leading, 10).frame(height: 34).background(Theme.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
            PanelContent(slot: slot, projectId: projectId, setConfig: { k, v in setConfig(slot.id, k, v) })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .background(Theme.surface)
    }

    // MARK: layout operations
    func add(_ k: PanelKind) {
        if layout.columns.count < 4 && !portrait {
            layout.columns.append(LayoutColumn(width: 0.25, panels: [PanelSlot(kind: k)], heights: [1]))
        } else if let i = layout.columns.indices.min(by: { layout.columns[$0].panels.count < layout.columns[$1].panels.count }) {
            layout.columns[i].panels.append(PanelSlot(kind: k)); layout.columns[i].heights.append(1 / CGFloat(layout.columns[i].panels.count))
        }
        layout.maximized = nil; layout.normalise()
        if compact { page = layout.columns.flatMap(\.panels).last { $0.kind == k }?.id }
    }
    func close(_ id: UUID) {
        guard let loc = layout.locate(id) else { return }
        let (c, r) = loc
        layout.columns[c].panels.remove(at: r); layout.columns[c].heights.remove(at: r)
        if layout.columns.allSatisfy({ $0.panels.isEmpty }) { layout = portrait ? .portrait() : .standard(); return }
        layout.normalise()
    }
    func replace(_ id: UUID, with k: PanelKind) { if let loc = layout.locate(id) { layout.columns[loc.0].panels[loc.1] = PanelSlot(kind: k) } }
    func setConfig(_ id: UUID, _ k: String, _ v: String?) { if let loc = layout.locate(id) { layout.columns[loc.0].panels[loc.1].config[k] = v } }
    func split(_ id: UUID) {
        guard let loc = layout.locate(id) else { return }
        let (c, r) = loc
        let h = layout.columns[c].heights[r] / 2
        layout.columns[c].heights[r] = h
        layout.columns[c].panels.insert(PanelSlot(kind: .terminal), at: r + 1); layout.columns[c].heights.insert(h, at: r + 1)
    }
    func move(_ id: UUID, dc: Int, dr: Int) {
        guard let loc = layout.locate(id) else { return }
        let (c, r) = loc
        let slot = layout.columns[c].panels[r]
        if dr != 0 {
            let to = r + dr
            guard to >= 0, to < layout.columns[c].panels.count else { return }
            layout.columns[c].panels.swapAt(r, to); layout.columns[c].heights.swapAt(r, to)
            return
        }
        layout.columns[c].panels.remove(at: r); layout.columns[c].heights.remove(at: r)
        let target = c + dc
        if target < 0 { layout.columns.insert(LayoutColumn(width: 0.25, panels: [slot], heights: [1]), at: 0) }
        else if target >= layout.columns.count { layout.columns.append(LayoutColumn(width: 0.25, panels: [slot], heights: [1])) }
        else { layout.columns[target].panels.append(slot); layout.columns[target].heights.append(1 / CGFloat(layout.columns[target].panels.count)) }
        layout.normalise()
    }
    func resizeColumn(_ c: Int, _ delta: CGFloat) {
        guard c + 1 < layout.columns.count else { return }
        let a = layout.columns[c].width + delta, b = layout.columns[c + 1].width - delta
        guard a > 0.12, b > 0.12 else { return }
        layout.columns[c].width = a; layout.columns[c + 1].width = b
    }
    func resizeRow(_ c: Int, _ r: Int, _ delta: CGFloat) {
        guard r + 1 < layout.columns[c].heights.count else { return }
        let a = layout.columns[c].heights[r] + delta, b = layout.columns[c].heights[r + 1] - delta
        guard a > 0.1, b > 0.1 else { return }
        layout.columns[c].heights[r] = a; layout.columns[c].heights[r + 1] = b
    }
}

extension Array {
    subscript(safe i: Int, default d: Element) -> Element { indices.contains(i) ? self[i] : d }
}

/// 1 pt line with a wide invisible grab area and a pointer/hover affordance.
struct ColumnDivider: View {
    let onDrag: (CGFloat) -> Void
    @State private var last: CGFloat = 0
    @State private var active = false
    var body: some View {
        Rectangle().fill(active ? Theme.accent : Theme.line).frame(width: 1)
            .overlay(Color.clear.frame(width: 14).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in active = true; onDrag(v.translation.width - last); last = v.translation.width }
                    .onEnded { _ in last = 0; active = false })
                .hoverEffect(.highlight))
            .zIndex(1)
            .accessibilityHidden(true)
    }
}

struct RowDivider: View {
    let onDrag: (CGFloat) -> Void
    @State private var last: CGFloat = 0
    @State private var active = false
    var body: some View {
        Rectangle().fill(active ? Theme.accent : Theme.line).frame(height: 1)
            .overlay(Color.clear.frame(height: 14).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in active = true; onDrag(v.translation.height - last); last = v.translation.height }
                    .onEnded { _ in last = 0; active = false })
                .hoverEffect(.highlight))
            .zIndex(1)
            .accessibilityHidden(true)
    }
}

struct PanelContent: View {
    let slot: PanelSlot
    let projectId: String
    let setConfig: (String, String?) -> Void
    @Environment(AppModel.self) private var app
    @Environment(TerminalStore.self) private var terminals

    var body: some View {
        switch slot.kind {
        case .files: FileBrowser(projectId: projectId)
        case .editor: FileViewerPanel(projectId: projectId)
        case .agents: WorkspaceAgentsPanel(projectId: projectId, selected: slot.config["agent"], select: { setConfig("agent", $0) })
        case .follow: FollowPanel(project: projectId)
        case .terminal: workspaceTerminal
        case .preview: PreviewPanel(projectId: projectId)
        case .screenshots: ScreenshotGallery(project: projectId)
        case .git: GitPanel(projectId: projectId)
        case .builds: BuildsPanel(projectId: projectId)
        case .timeline: ProjectTimeline(projectId: projectId)
        case .desktop: RemoteDesktopPanel(initialDisplay: slot.config["display"] ?? "99")
        }
    }

    var workspaceTerminal: some View {
        WorkspaceTerminal(name: slot.config["tmux"] ?? "mc-ws-\(projectId.prefix(20))-\(slot.id.uuidString.prefix(4).lowercased())",
                          projectId: projectId, persist: { if slot.config["tmux"] == nil { setConfig("tmux", $0) } })
    }
}

/// Each terminal panel owns a named tmux session, so it survives app restarts.
struct WorkspaceTerminal: View {
    let name: String
    let projectId: String
    let persist: (String) -> Void
    @Environment(AppModel.self) private var app
    @Environment(TerminalStore.self) private var terminals
    @State private var session: TerminalSession?
    var body: some View {
        Group { if let session { TerminalPane(session: session) } else { Color(Theme.terminalBg) } }
            .onAppear {
                session = terminals.panelSession(name, title: app.project(projectId)?.name, directory: app.project(projectId)?.path)
                persist(name)
            }
            .onDisappear {
                // Let SwiftUI finish removing the view before checking it's really gone.
                let store = terminals
                Task { @MainActor in try? await Task.sleep(nanoseconds: 1_000_000_000); store.releasePanel(name) }
            }
    }
}

/// Agents for one project: pick one, see its activity, approve, instruct.
struct WorkspaceAgentsPanel: View {
    let projectId: String
    let selected: String?
    let select: (String?) -> Void
    @Environment(AppModel.self) private var app

    var agents: [Agent] { app.agents.filter { $0.project == projectId && ($0.status != "ended" || Date().timeIntervalSince1970 * 1000 - $0.lastActivity < 6 * 3600_000) } }
    var current: Agent? { app.agent(selected) ?? agents.first }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(agents) { a in
                        Button { select(a.id) } label: {
                            HStack(spacing: 5) { StatusDot(status: a.status, size: 6); Text(a.title).font(.system(size: 12.5)).lineLimit(1).frame(maxWidth: 160) }
                                .padding(.horizontal, 8).frame(height: 26)
                                .background(current?.id == a.id ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain)
                    }
                    Button { app.launcherProject = projectId; app.showLauncher = true } label: { Label("New", systemImage: "plus").font(.system(size: 12.5)).padding(.horizontal, 8).frame(height: 26) }.buttonStyle(.plain).foregroundStyle(Theme.accent)
                }.padding(4)
            }
            .background(Theme.bg)
            if let a = current {
                if let p = a.approval { ScrollView { ApprovalCard(agent: a, prompt: p).padding(8) }.frame(maxHeight: 300) }
                AgentTimeline(agent: a).id(a.id)
                AgentComposer(agent: a)
            } else {
                EmptyNote(icon: "sparkles", text: "No agents in this project", detail: "Start Claude Code or Codex here with New.")
            }
        }
    }
}

struct ProjectTimeline: View {
    let projectId: String
    @Environment(AppModel.self) private var app
    @State private var events: [TimelineEvent] = []
    @State private var selected: TimelineEvent?
    @State private var kinds: Set<String> = []
    let filters: [(String, String, [String])] = [
        ("Agents", "sparkles", ["agent.prompt", "agent.message", "agent.done", "agent.started", "agent.instruction"]),
        ("Edits", "pencil.line", ["agent.edit", "file.changed", "file.saved"]),
        ("Commands", "terminal", ["agent.command", "agent.command_failed", "agent.test"]),
        ("Images", "photo", ["agent.image", "screenshot.new"]),
        ("Approvals", "hand.raised", ["agent.approval", "agent.approval_answered"]),
        ("Builds & git", "hammer", ["build.started", "build.finished", "git.commit", "git.push", "ci.finished"]),
        ("Errors", "exclamationmark.triangle", ["agent.error", "server.alert"]),
    ]

    var merged: [TimelineEvent] {
        var seen = Set<String>()
        return (events + app.liveEvents.filter { $0.project == projectId }).filter { seen.insert($0.stableId).inserted }
            .filter { kinds.isEmpty || kinds.contains($0.kind) }.sorted { $0.ts > $1.ts }.prefix(500).map { $0 }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(filters, id: \.0) { f in
                            let on = Set(f.2).isSubset(of: kinds)
                            Button { if on { kinds.subtract(f.2) } else { kinds.formUnion(f.2) } } label: {
                                Label(f.0, systemImage: f.1).font(.system(size: 12)).padding(.horizontal, 8).frame(height: 24)
                                    .background(on ? Theme.accent.opacity(0.2) : Theme.hover, in: Capsule())
                            }.buttonStyle(.plain)
                        }
                    }.padding(6)
                }
                List(merged, id: \.stableId) { e in
                    EventRow(event: e, showProject: false).listRowBackground(selected?.stableId == e.stableId ? Theme.hover : Theme.surface)
                        .onTapGesture { selected = e }
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
            }
            if let s = selected { Divider().overlay(Theme.line); EvidenceView(event: s, close: { selected = nil }).frame(minWidth: 320) }
        }
        .task(id: projectId) { events = (try? await app.client.get("/api/timeline", ["project": projectId, "limit": "500"], as: [TimelineEvent].self)) ?? [] }
    }
}
