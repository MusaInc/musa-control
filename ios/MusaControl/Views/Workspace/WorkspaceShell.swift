import SwiftUI
import UniformTypeIdentifiers

/// iPad: the whole app is this one workspace.
///
///   top bar     project · layout presets · agents · Remote Desktop · account
///   activity    Files / Agents / Source Control navigator, Visualiser, settings
///   panels      resizable split panels (editor, terminal, agent, visualiser…)
///   desktop     beside the panels (split) or floating / full / mini over them
///   status bar  connection · agents · desktop · minimised panels · keyboard focus
struct WorkspaceShell: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        GeometryReader { geo in
            let narrow = geo.size.width < 760
            VStack(spacing: 0) {
                WorkspaceTopBar(narrow: narrow)
                if case .offline(let msg) = app.phase { OfflineBar(message: msg) }
                HStack(spacing: 0) {
                    ActivityBar()
                    Rectangle().fill(Theme.line).frame(width: 1)
                    if app.workspace.navigatorVisible && !narrow {
                        NavigatorView()
                            .frame(width: app.workspace.navigatorWidth)
                        ColumnDivider { dx in app.workspace.navigatorWidth = min(420, max(200, app.workspace.navigatorWidth + dx)) }
                    }
                    MainArea(size: CGSize(width: geo.size.width - 49 - (app.workspace.navigatorVisible && !narrow ? app.workspace.navigatorWidth + 1 : 0), height: geo.size.height - 62))
                        .environment(\.compactLayout, narrow)
                }
                WorkspaceStatusBar()
            }
            .overlay { DesktopOverlay(size: geo.size) }
            .overlay(alignment: .leading) {
                if narrow && app.workspace.navigatorVisible {
                    ZStack(alignment: .leading) {
                        Color.black.opacity(0.22).ignoresSafeArea().onTapGesture { withAnimation(.snappy(duration: 0.2)) { app.workspace.navigatorVisible = false } }
                        NavigatorView().frame(width: min(320, geo.size.width - 60)).background(Theme.surface)
                            .shadow(color: .black.opacity(0.2), radius: 16, x: 4)
                            .padding(.leading, 49).padding(.top, 40).padding(.bottom, 24)
                    }
                    .transition(.opacity)
                }
            }
            .onAppear { app.workspace.setPortrait(geo.size.width < geo.size.height) }
            .onChange(of: geo.size.width < geo.size.height) { _, p in app.workspace.setPortrait(p) }
        }
        .background(Theme.bg)
    }
}

// MARK: - Top bar

struct WorkspaceTopBar: View {
    let narrow: Bool
    @Environment(AppModel.self) private var app

    var liveAgents: [Agent] {
        app.agents.filter { $0.isLive && ($0.project == app.workspace.projectId || $0.status == "approval") }
    }
    var waiting: Int { app.agents.filter { $0.status == "approval" }.count }

    var body: some View {
        HStack(spacing: 6) {
            Image("SidebarMark").resizable().frame(width: 22, height: 22).clipShape(RoundedRectangle(cornerRadius: 5)).padding(.leading, 12)
            ProjectMenu()
            if !narrow { presets }
            Spacer(minLength: 8)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) { ForEach(liveAgents.prefix(5)) { a in agentChip(a) } }
            }
            .frame(maxWidth: narrow ? 120 : 420)
            .fixedSize(horizontal: !narrow, vertical: false)
            if waiting > 0 {
                Button { if let a = app.agents.first(where: { $0.status == "approval" }) { app.showAgent(a.id) } } label: {
                    Label("\(waiting) waiting", systemImage: "hand.raised.fill").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 9).frame(height: 24).background(Theme.yellow.opacity(0.2), in: Capsule()).foregroundStyle(Theme.yellow)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("approvals.pill")
            }
            Button { app.launcherProject = app.workspace.projectId; app.showLauncher = true } label: {
                Label("Agent", systemImage: "plus").font(.system(size: 12.5, weight: .semibold))
                    .padding(.horizontal, 10).frame(height: 26).background(Theme.accent.opacity(0.16), in: Capsule()).foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain).help("New agent task (⇧⌘N)")
            .accessibilityIdentifier("workspace.newAgent")
            desktopButton
            AccountMenu()
        }
        .padding(.trailing, 8)
        .frame(height: 40)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    var presets: some View {
        HStack(spacing: 0) {
            ForEach(WorkspaceLayout.Preset.allCases) { p in
                Button { withAnimation(.snappy(duration: 0.25)) { app.workspace.apply(p) } } label: {
                    Label(p.title, systemImage: p.icon).labelStyle(.iconOnly).font(.system(size: 13))
                        .frame(width: 32, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(Theme.textDim).help("\(p.title) layout")
                .accessibilityLabel("\(p.title) layout").accessibilityIdentifier("preset.\(p.rawValue)")
            }
            Menu {
                ForEach(PanelKind.allCases) { k in
                    Button { app.workspace.add(k) } label: { Label("Add \(k.title)", systemImage: k.icon) }
                }
                Divider()
                Button { app.workspace.apply(.agent) } label: { Label("Reset layout", systemImage: "arrow.counterclockwise") }
            } label: { Image(systemName: "rectangle.badge.plus").font(.system(size: 13)).frame(width: 32, height: 26) }
            .accessibilityIdentifier("workspace.addPanel")
        }
        .background(Theme.hover.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
        .padding(.leading, 6)
    }

    func agentChip(_ a: Agent) -> some View {
        Button { app.showAgent(a.id) } label: {
            HStack(spacing: 5) {
                StatusDot(status: a.status, size: 6)
                Text(a.shortName).font(.system(size: 12, weight: .semibold)).foregroundStyle(a.tint)
                if !narrow { Text(a.title).font(.system(size: 12)).foregroundStyle(Theme.textDim).lineLimit(1).frame(maxWidth: 120) }
            }
            .padding(.horizontal, 8).frame(height: 24)
            .background(Theme.hover.opacity(0.7), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("\(a.agentName): \(a.statusText)")
    }

    var desktopButton: some View {
        Button { withAnimation(.snappy(duration: 0.25)) { app.toggleDesktop() } } label: {
            Image(systemName: app.desktop.active ? "display.trianglebadge.exclamationmark" : "display")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(app.desktop.active ? Theme.accent : Theme.textDim)
                .frame(width: 34, height: 30)
        }
        .buttonStyle(.plain)
        .help(app.desktop.active ? "Close Remote Desktop (⌃⌘D)" : "Open Remote Desktop (⌃⌘D)")
        .accessibilityLabel(app.desktop.active ? "Close Remote Desktop" : "Open Remote Desktop")
        .accessibilityIdentifier("desktop.toggle")
    }
}

/// Project name with every project a tap away.
struct ProjectMenu: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        Menu {
            ForEach(app.projects) { p in
                Button { app.openWorkspace(p.id) } label: {
                    Label(p.name + ((p.activeAgents ?? 0) > 0 ? "  ·  \(p.activeAgents!) agent\(p.activeAgents == 1 ? "" : "s")" : ""),
                          systemImage: p.id == app.workspace.projectId ? "checkmark" : p.icon)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(app.project(app.workspace.projectId)?.name ?? "Choose a project").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 6).frame(height: 28)
        }
        .accessibilityIdentifier("workspace.project")
    }
}

/// Machine, connection and account: switch computers, reconnect, sign in
/// or out, all from one place.
struct AccountMenu: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        Menu {
            Section("Computers") {
                ForEach(app.machines) { m in
                    Button { Task { await app.activate(m) } } label: { Label(m.name, systemImage: m.id == app.activeMachine?.id ? "checkmark" : m.symbol) }
                }
                Button { app.showAddMachine = true; app.sheet = .machines } label: { Label("Add a computer…", systemImage: "plus") }
            }
            Section {
                if case .offline = app.phase { Button { Task { await app.connect() } } label: { Label("Reconnect now", systemImage: "arrow.clockwise") } }
                else { Button { app.suspend(); app.phase = .offline("Disconnected") } label: { Label("Disconnect", systemImage: "bolt.slash") } }
                Button { app.sheet = .machines } label: { Label("Machines & AI accounts…", systemImage: "desktopcomputer") }
                Button { app.sheet = .settings } label: { Label("Settings…", systemImage: "gearshape") }
            }
            Section {
                Button(role: .destructive) { app.unpair() } label: { Label("Sign out of \(app.activeMachine?.name ?? "this computer")", systemImage: "rectangle.portrait.and.arrow.right") }
            }
        } label: {
            HStack(spacing: 6) {
                ConnectionDot()
                Text(app.activeMachine?.name ?? "Not connected").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textDim).lineLimit(1).frame(maxWidth: 150)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(Theme.hover.opacity(0.5), in: Capsule())
        }
        .accessibilityIdentifier("machine.switcher")
    }
}

// MARK: - Activity bar + navigator

struct ActivityBar: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        VStack(spacing: 4) {
            ForEach(NavigatorTab.allCases) { t in
                let on = app.workspace.navigatorVisible && app.workspace.navigator == t
                item(t.icon, t.title, on: on, badge: t == .agents ? app.agents.filter { $0.status == "approval" }.count : 0) {
                    withAnimation(.snappy(duration: 0.2)) {
                        if on { app.workspace.navigatorVisible = false } else { app.workspace.navigator = t; app.workspace.navigatorVisible = true }
                    }
                }
                .accessibilityIdentifier("nav.\(t.rawValue)")
            }
            Rectangle().fill(Theme.line).frame(width: 24, height: 1).padding(.vertical, 4)
            item("chart.xyaxis.line", "Visualiser", on: app.workspace.layout.slots.contains { $0.kind == .visualiser }) { app.workspace.reveal(.visualiser) }
                .accessibilityIdentifier("nav.visualiser")
            item("display", "Remote Desktop", on: app.desktop.active) { withAnimation(.snappy(duration: 0.25)) { app.toggleDesktop() } }
                .accessibilityIdentifier("nav.desktop")
            Spacer()
            item("desktopcomputer", "Machines & AI", on: false) { app.sheet = .machines }
                .accessibilityIdentifier("nav.machines")
            item("gearshape", "Settings", on: false) { app.sheet = .settings }
                .accessibilityIdentifier("nav.settings")
        }
        .padding(.vertical, 8)
        .frame(width: 48)
        .background(Theme.surface)
    }

    func item(_ icon: String, _ title: String, on: Bool, badge: Int = 0, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 16, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Theme.accent : Theme.textDim)
                .frame(width: 38, height: 36)
                .background(on ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topTrailing) {
                    if badge > 0 { Text("\(badge)").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.onAccent).padding(.horizontal, 4).background(Theme.yellow, in: Capsule()).offset(x: 2, y: -1) }
                }
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .help(title)
        .accessibilityLabel(Text(badge > 0 ? "\(title), \(badge) waiting" : title))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct NavigatorView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(app.workspace.navigator.title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.textFaint)
                Spacer()
                if app.workspace.navigator == .agents {
                    IconButton(systemName: "plus", help: "New agent task") { app.launcherProject = app.workspace.projectId; app.showLauncher = true }
                }
            }
            .padding(.leading, 12).padding(.trailing, 4).frame(height: 32)
            Group {
                if let p = app.workspace.projectId, app.project(p) != nil {
                    switch app.workspace.navigator {
                    case .files: FileBrowser(projectId: p, onOpen: { app.workspace.reveal(.editor) }).id(p)
                    case .agents: AgentsNavigator()
                    case .git: GitPanel(projectId: p).environment(\.compactLayout, true).id(p)
                    }
                } else if app.workspace.navigator == .agents {
                    AgentsNavigator()
                } else {
                    EmptyNote(icon: "folder", text: "Choose a project", detail: "Pick one from the project menu at the top left.")
                }
            }
            .frame(maxHeight: .infinity)
        }
        .background(Theme.surface)
    }
}

/// Every agent session on this computer: what needs you, what's working,
/// what's paused or idle, what ran recently. One tap opens it live.
struct AgentsNavigator: View {
    @Environment(AppModel.self) private var app
    @AppStorage("nav.agents.allProjects") private var allProjects = false

    var scoped: [Agent] { app.agents.filter { allProjects || app.workspace.projectId == nil || $0.project == app.workspace.projectId || $0.status == "approval" } }
    var groups: [(String, [Agent])] {
        let now = Date().timeIntervalSince1970 * 1000
        return [
            ("Needs you", scoped.filter { $0.status == "approval" }),
            ("Working", scoped.filter { $0.status == "working" }),
            ("Paused", scoped.filter { $0.status == "paused" }),
            ("Idle", scoped.filter { $0.status == "idle" }),
            ("Recent", scoped.filter { !$0.isLive && $0.status != "approval" && now - $0.lastActivity < 3 * 86400_000 }.prefix(15).map { $0 }),
        ].filter { !$0.1.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $allProjects) { Text("This project").tag(false); Text("All projects").tag(true) }
                .pickerStyle(.segmented).padding(.horizontal, 8).padding(.bottom, 6)
            List {
                ForEach(groups, id: \.0) { g in
                    SwiftUI.Section {
                        ForEach(g.1) { a in row(a) }
                    } header: { Text(g.0).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textFaint) }
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .overlay { if groups.isEmpty { EmptyNote(icon: "sparkles", text: "No agents yet", detail: "Start Claude, Codex or Gemini with + above.") } }
            Button { app.sheet = .machines } label: {
                Label("AI accounts & sign-in", systemImage: "person.crop.circle.badge.checkmark").font(Theme.caption).frame(maxWidth: .infinity).frame(height: 30)
            }
            .buttonStyle(.plain).foregroundStyle(Theme.textDim)
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        }
    }

    func row(_ a: Agent) -> some View {
        Button { app.showAgent(a.id) } label: {
            HStack(alignment: .top, spacing: 8) {
                StatusDot(status: a.status, size: 7).padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(a.shortName).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(a.tint)
                        if allProjects, let p = app.project(a.project) { Text(p.name).font(.system(size: 11)).foregroundStyle(Theme.textFaint).lineLimit(1) }
                        Spacer(minLength: 0)
                        Text(Fmt.ago(a.lastActivity)).font(.system(size: 10.5)).foregroundStyle(Theme.textFaint)
                    }
                    Text(a.title).font(.system(size: 13)).foregroundStyle(Theme.text).lineLimit(2)
                    Text(a.status == "approval" ? "Waiting for your approval" : a.statusText).font(.system(size: 11.5)).foregroundStyle(a.status == "approval" ? Theme.yellow : Theme.textDim).lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Theme.surface)
        .listRowInsets(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
        .contextMenu {
            if let t = a.tmux?.session { Button { app.showTerminal(tmux: t, title: a.shortName) } label: { Label("Open its terminal", systemImage: "terminal") } }
            if a.isLive && a.controllable {
                Button { Task { _ = try? await app.client.send("POST", "/api/agents/\(a.id.pathSegment)/interrupt", [:], as: OK.self); await app.refreshAgents() } } label: { Label("Interrupt", systemImage: "stop.circle") }
                if a.status == "paused" { Button { Task { _ = try? await app.client.send("POST", "/api/agents/\(a.id.pathSegment)/resume", [:], as: OK.self); await app.refreshAgents() } } label: { Label("Resume", systemImage: "play") } }
                else { Button { Task { _ = try? await app.client.send("POST", "/api/agents/\(a.id.pathSegment)/pause", [:], as: OK.self); await app.refreshAgents() } } label: { Label("Pause", systemImage: "pause") } }
            }
        }
        .accessibilityIdentifier("agentrow.\(a.id)")
    }
}

// MARK: - Panels + desktop split

struct MainArea: View {
    let size: CGSize
    @Environment(AppModel.self) private var app

    var body: some View {
        let desk = app.desktop
        let split = desk.active && desk.presentation == .split
        let sideBySide = size.width >= size.height * 0.95
        Group {
            if split {
                if sideBySide {
                    HStack(spacing: 0) {
                        PanelArea(size: CGSize(width: size.width * (1 - desk.splitFraction) - 1, height: size.height))
                            .frame(width: size.width * (1 - desk.splitFraction) - 1)
                        ColumnDivider { dx in desk.splitFraction = min(0.8, max(0.25, desk.splitFraction - dx / max(size.width, 1))) }
                        DesktopPane(chrome: .full)
                    }
                } else {
                    VStack(spacing: 0) {
                        DesktopPane(chrome: .full).frame(height: size.height * desk.splitFraction)
                        RowDivider { dy in desk.splitFraction = min(0.8, max(0.25, desk.splitFraction + dy / max(size.height, 1))) }
                        PanelArea(size: CGSize(width: size.width, height: size.height * (1 - desk.splitFraction) - 1))
                    }
                }
            } else {
                PanelArea(size: size)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PanelArea: View {
    let size: CGSize
    @Environment(AppModel.self) private var app
    @Environment(\.compactLayout) private var compact

    var body: some View {
        let ws = app.workspace
        Group {
            if ws.projectId == nil || app.project(ws.projectId) == nil {
                ProjectGrid()
            } else if ws.layout.columns.isEmpty {
                VStack(spacing: 12) {
                    EmptyNote(icon: "rectangle.split.3x1", text: "No panels open", detail: "Pick a layout, or add a panel.")
                    HStack { ForEach(WorkspaceLayout.Preset.allCases) { p in Button { ws.apply(p) } label: { Label(p.title, systemImage: p.icon) }.buttonStyle(.bordered) } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if compact || size.width < 520 {
                PagedPanels()
            } else if let m = ws.layout.maximized, let loc = ws.layout.locate(m) {
                PanelChrome(slot: ws.layout.columns[loc.0].panels[loc.1], column: loc.0, row: loc.1)
            } else {
                columns
            }
        }
        .background(Theme.line)
    }

    var columns: some View {
        let ws = app.workspace
        let usable = size.width - CGFloat(max(ws.layout.columns.count - 1, 0))
        return HStack(spacing: 0) {
            ForEach(Array(ws.layout.columns.enumerated()), id: \.element.id) { c, col in
                VStack(spacing: 0) {
                    let rowUsable = size.height - CGFloat(max(col.panels.count - 1, 0))
                    ForEach(Array(col.panels.enumerated()), id: \.element.id) { r, slot in
                        PanelChrome(slot: slot, column: c, row: r)
                            .frame(height: max(90, rowUsable * col.heights[safe: r, default: 1 / CGFloat(col.panels.count)]))
                        if r < col.panels.count - 1 { RowDivider { dy in ws.resizeRow(c, r, dy / max(rowUsable, 1)) } }
                    }
                }
                .frame(width: max(240, usable * col.width))
                if c < ws.layout.columns.count - 1 { ColumnDivider { dx in ws.resizeColumn(c, dx / max(usable, 1)) } }
            }
        }
    }
}

/// Narrow windows and iPhone: one panel at a time, picked from a strip.
struct PagedPanels: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let ws = app.workspace
        let slots = ws.layout.slots
        let current = slots.first { $0.id == ws.page } ?? slots.first
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(slots) { slot in
                        let on = slot.id == current?.id
                        Button { ws.page = slot.id; ws.focused = slot.id } label: {
                            Label(slot.kind.title, systemImage: slot.kind.icon).font(.system(size: 13, weight: on ? .semibold : .regular))
                                .padding(.horizontal, 11).frame(height: 30)
                                .background(on ? Theme.accent.opacity(0.18) : Theme.hover, in: Capsule())
                                .foregroundStyle(on ? Theme.accent : Theme.textDim)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("page.\(slot.kind.rawValue)")
                        .contextMenu {
                            ForEach(PanelKind.allCases) { k in Button { ws.replace(slot.id, with: k) } label: { Label("Show \(k.title)", systemImage: k.icon) } }
                            Divider()
                            Button(role: .destructive) { ws.close(slot.id) } label: { Label("Close panel", systemImage: "xmark") }
                        }
                    }
                    Menu {
                        ForEach(PanelKind.allCases) { k in Button { ws.add(k) } label: { Label(k.title, systemImage: k.icon) } }
                    } label: { Image(systemName: "plus").frame(width: 30, height: 30).background(Theme.hover, in: Circle()) }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
            .background(Theme.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
            if let slot = current, let p = ws.projectId {
                PanelContent(slot: slot, projectId: p).id(slot.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.surface)
            }
        }
    }
}

/// A panel's header and content. Drag the header onto another panel to
/// move it there (top/bottom half: same column, left/right edge: new column).
struct PanelChrome: View {
    let slot: PanelSlot
    let column: Int
    let row: Int
    @Environment(AppModel.self) private var app
    @State private var dropTarget: WorkspaceStore.Drop?
    @State private var size: CGSize = .zero

    var focused: Bool { app.workspace.focused == slot.id && app.workspace.layout.slots.count > 1 }

    var body: some View {
        let ws = app.workspace
        VStack(spacing: 0) {
            header(ws)
            if let p = ws.projectId {
                PanelContent(slot: slot, projectId: p)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
        }
        .background(Theme.surface)
        .overlay { if focused { Rectangle().stroke(Theme.accent.opacity(0.55), lineWidth: 1.5).allowsHitTesting(false) } }
        .overlay { dropHighlight }
        .simultaneousGesture(TapGesture().onEnded { if ws.focused != slot.id { ws.focused = slot.id } })
        .background(GeometryReader { g in Color.clear.onAppear { size = g.size }.onChange(of: g.size) { _, v in size = v } })
        .onDrop(of: [UTType.plainText], delegate: QuadrantDrop(size: size, slotId: slot.id, ws: ws, target: $dropTarget))
    }

    // While a panel is dragged over this one, show where it would land.
    @ViewBuilder var dropHighlight: some View {
        if let d = dropTarget {
            let r: CGRect = {
                switch d {
                case .above: return CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)
                case .below: return CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
                case .left: return CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)
                case .right: return CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
                }
            }()
            Rectangle().fill(Theme.accent.opacity(0.14)).overlay(Rectangle().stroke(Theme.accent, lineWidth: 2))
                .frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
                .allowsHitTesting(false)
        }
    }

    func header(_ ws: WorkspaceStore) -> some View {
        HStack(spacing: 2) {
            Image(systemName: slot.kind.icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(focused ? Theme.accent : Theme.textDim)
                .frame(width: 22)
                .accessibilityIdentifier("panel.\(slot.kind.rawValue)")   // on a leaf: container ids hide their children
            Menu {
                ForEach(PanelKind.allCases) { k in Button { ws.replace(slot.id, with: k) } label: { Label(k.title, systemImage: k.icon) } }
            } label: {
                HStack(spacing: 4) {
                    Text(slot.kind.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                    if let s = subtitle { Text(s).font(.system(size: 11.5)).foregroundStyle(Theme.textFaint).lineLimit(1).truncationMode(.middle) }
                }
            }
            Spacer(minLength: 4)
            IconButton(systemName: "rectangle.split.1x2", help: "Split: new terminal below (⌘D)") { _ = ws.add(.terminal, beside: slot.id) }
            IconButton(systemName: "minus", help: "Minimise to the status bar") { withAnimation(.snappy(duration: 0.2)) { ws.minimize(slot.id) } }
            IconButton(systemName: ws.layout.maximized == slot.id ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                       help: ws.layout.maximized == slot.id ? "Restore (⌃⌘M)" : "Maximise (⌃⌘M)") { withAnimation(.snappy(duration: 0.2)) { ws.toggleMaximize(slot.id) } }
            IconButton(systemName: "xmark", help: "Close panel") { withAnimation(.snappy(duration: 0.2)) { ws.close(slot.id) } }
        }
        .padding(.leading, 4).frame(height: 30)
        .background(focused ? Theme.raised : Theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .contentShape(Rectangle())
        .draggable(slot.id.uuidString) {
            Label(slot.kind.title, systemImage: slot.kind.icon).font(.system(size: 13, weight: .semibold)).padding(8)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    var subtitle: String? {
        switch slot.kind {
        case .terminal: return slot.config["title"] ?? slot.config["tmux"].map { $0.hasPrefix("mc-ws-") ? "shell" : $0 }
        case .agent: return slot.config["agent"].flatMap { app.agent($0)?.title } ?? "following"
        case .editor: return app.workspace.projectId.flatMap { FilesState.shared.openPath[$0] }.map { ($0 as NSString).lastPathComponent }
        default: return nil
        }
    }
}

/// Works out which side of a panel a dragged panel header is over, and
/// moves it there on drop.
struct QuadrantDrop: DropDelegate {
    let size: CGSize
    let slotId: UUID
    let ws: WorkspaceStore
    @Binding var target: WorkspaceStore.Drop?
    func quadrant(_ p: CGPoint) -> WorkspaceStore.Drop {
        let edge = min(size.width * 0.22, 140)
        if p.x < edge { return .left }
        if p.x > size.width - edge { return .right }
        return p.y < size.height / 2 ? .above : .below
    }
    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [UTType.plainText]) }
    func dropEntered(info: DropInfo) { target = quadrant(info.location) }
    func dropUpdated(info: DropInfo) -> DropProposal? { target = quadrant(info.location); return DropProposal(operation: .move) }
    func dropExited(info: DropInfo) { target = nil }
    func performDrop(info: DropInfo) -> Bool {
        let t = quadrant(info.location)
        target = nil
        guard let item = info.itemProviders(for: [UTType.plainText]).first else { return false }
        let ws = ws, slotId = slotId
        _ = item.loadObject(ofClass: NSString.self) { obj, _ in
            guard let s = obj as? String, let id = UUID(uuidString: s) else { return }
            Task { @MainActor in withAnimation(.snappy(duration: 0.25)) { ws.drop(id, on: slotId, t) } }
        }
        return true
    }
}

struct PanelContent: View {
    let slot: PanelSlot
    let projectId: String
    @Environment(AppModel.self) private var app

    var body: some View {
        let ws = app.workspace
        switch slot.kind {
        case .editor: EditorPanel(projectId: projectId)
        case .terminal:
            WorkspaceTerminal(slotId: slot.id, name: slot.config["tmux"] ?? "mc-ws-\(projectId.prefix(20))-\(slot.id.uuidString.prefix(4).lowercased())",
                              title: slot.config["title"], projectId: projectId,
                              persist: { if slot.config["tmux"] == nil { ws.setConfig(slot.id, "tmux", $0) } })
        case .agent: AgentLivePanel(projectId: projectId, agentConfig: slot.config["agent"], setAgent: { ws.setConfig(slot.id, "agent", $0) })
        case .visualiser: VisualiserPanel(projectId: projectId, selected: slot.config["item"], select: { ws.setConfig(slot.id, "item", $0) })
        case .preview: PreviewPanel(projectId: projectId)
        case .builds: BuildsPanel(projectId: projectId)
        }
    }
}

struct EditorPanel: View {
    let projectId: String
    @Environment(AppModel.self) private var app
    @State private var files = FilesState.shared
    var body: some View {
        if files.openPath[projectId] != nil {
            FileViewerPanel(projectId: projectId)
        } else {
            VStack(spacing: 10) {
                EmptyNote(icon: "doc.text", text: "No file open", detail: "Open one from Files in the navigator, with Quick Open (⌘P), or from anything an agent touched.")
                Button { app.workspace.navigator = .files; app.workspace.navigatorVisible = true } label: { Label("Show files", systemImage: "folder") }.buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Each terminal panel owns a named tmux session, so it survives app
/// restarts and disconnects; focusing the panel gives it the keyboard.
struct WorkspaceTerminal: View {
    let slotId: UUID
    let name: String
    let title: String?
    let projectId: String
    let persist: (String) -> Void
    @Environment(AppModel.self) private var app
    @Environment(TerminalStore.self) private var terminals
    @State private var session: TerminalSession?
    var body: some View {
        Group { if let session { TerminalPane(session: session) } else { Color(Theme.terminalBg) } }
            .onAppear {
                session = terminals.panelSession(name, title: title ?? app.project(projectId)?.name, directory: app.project(projectId)?.path)
                persist(name)
                if app.workspace.focused == slotId { focusSoon() }
            }
            .onChange(of: app.workspace.focused) { _, f in if f == slotId { focusSoon() } }
            .onDisappear {
                let store = terminals
                Task { @MainActor in try? await Task.sleep(nanoseconds: 1_000_000_000); store.releasePanel(name) }
            }
    }
    func focusSoon() {
        let s = session
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { _ = s?.view.becomeFirstResponder() }
    }
}

/// 1 pt line with a wide invisible grab area and a hover affordance.
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

struct ProjectGrid: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Open a project").font(.system(size: 20, weight: .semibold))
                Text("Each project keeps its own panels, files, agents and terminals.").font(Theme.caption).foregroundStyle(Theme.textDim)
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
        .background(Theme.bg)
    }
}

// MARK: - Status bar

struct WorkspaceStatusBar: View {
    @Environment(AppModel.self) private var app
    @State private var keys = KeyboardFocus.shared

    var body: some View {
        let working = app.agents.filter { $0.status == "working" }.count
        let waiting = app.agents.filter { $0.status == "approval" }.count
        HStack(spacing: 12) {
            HStack(spacing: 5) { ConnectionDot(); Text(connection).lineLimit(1) }
            if working + waiting > 0 {
                Button { app.workspace.navigator = .agents; app.workspace.navigatorVisible = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                        Text("\(working) working\(waiting > 0 ? " · \(waiting) waiting" : "")")
                    }
                }.buttonStyle(.plain)
            }
            if app.desktop.active {
                Button { withAnimation(.snappy(duration: 0.25)) { app.desktop.presentation = app.desktop.presentation == .mini ? .floating : .mini } } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "display")
                        Text("Desktop :\(app.desktop.display) · \(app.desktop.connected ? (app.desktop.control ? "controlling" : "watching") : "reconnecting")")
                        if let r = app.desktop.rtt, app.desktop.connected { Text("\(r) ms").foregroundStyle(Theme.textFaint) }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("status.desktop")
            }
            ForEach(app.workspace.layout.minimized) { s in
                Button { withAnimation(.snappy(duration: 0.2)) { app.workspace.restore(s.id) } } label: {
                    Label(s.kind.title, systemImage: s.kind.icon).padding(.horizontal, 6).frame(height: 18).background(Theme.hover, in: Capsule())
                }
                .buttonStyle(.plain).help("Restore \(s.kind.title)")
            }
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: keys.target.icon)
                Text(keys.target.label).lineLimit(1)
                if !keys.hardwareKeyboard { Text("· no keyboard").foregroundStyle(Theme.textFaint) }
            }
            .foregroundStyle(keys.target == .none ? Theme.textFaint : Theme.textDim)
            .help("Where typing goes")
            .accessibilityIdentifier("status.keyboard")
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.textDim)
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(Theme.surface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        .onAppear { keys.start() }
    }

    var connection: String {
        switch (app.phase, app.streamState) {
        case (.ready, .live): return app.activeMachine?.name ?? "Connected"
        case (.offline, _): return "Offline — retrying"
        default: return "Connecting…"
        }
    }
}
