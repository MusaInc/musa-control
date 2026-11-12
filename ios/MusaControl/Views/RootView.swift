import SwiftUI

/// App shell: sidebar + content. The sidebar collapses to an icon rail, never
/// to nothing, so navigation can't be hidden by accident (the old split view
/// hid its own toggle along with the navigation bar, and a dismissed sidebar
/// had no way back). Narrow windows (Slide Over, Stage Manager, iPhone
/// widths) always show the rail; the full sidebar opens over the content and
/// closes on a tap outside or after navigating.
struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Group {
            if app.phase == .unpaired {
                WelcomeView()
            } else if Device.isPhone {
                PhoneShell()
            } else {
                GeometryReader { geo in
                    let compact = geo.size.width < 700
                    let full = app.sidebarExpanded && !compact
                    ZStack(alignment: .leading) {
                        HStack(spacing: 0) {
                            Sidebar(style: full ? .full : .rail, compact: compact)
                                .frame(width: full ? 236 : 64)
                            Rectangle().fill(Theme.line).frame(width: 1).ignoresSafeArea()
                            VStack(spacing: 0) {
                                if case .offline(let msg) = app.phase { OfflineBar(message: msg) }
                                SectionDetail().frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .environment(\.compactLayout, geo.size.width - (full ? 237 : 65) < 600)
                            }
                            .background(Theme.bg)
                        }
                        if compact && app.sidebarOverlay { SidebarOverlay(width: geo.size.width) }
                    }
                    // Swipe in from the left edge to show the full sidebar.
                    .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { v in
                        guard v.startLocation.x < 28, v.translation.width > 70, abs(v.translation.height) < 60 else { return }
                        withAnimation(.snappy(duration: 0.22)) { if compact { app.sidebarOverlay = true } else { app.sidebarExpanded = true } }
                    })
                    .onChange(of: compact) { _, _ in app.sidebarOverlay = false }
                }
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .overlay(alignment: .top) { if let b = app.banner { EventBanner(event: b).transition(.move(edge: .top).combined(with: .opacity)) } }
        .animation(.spring(duration: 0.35), value: app.banner?.stableId)
        .sheet(isPresented: $app.showLauncher) { AgentLauncher(initialProject: app.launcherProject) }
        .sheet(isPresented: $app.showSwitcher) { QuickSwitcher() }
    }
}

/// The selected section, or an agent's live studio over it.
struct SectionDetail: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        // The Command Deck hosts its own studio so a tile can grow into it.
        if let id = app.studioAgent, app.section != .deck {
            AgentStudioView(agentId: id).id(id)
        } else {
            switch app.section {
            case .home: HomeView()
            case .deck: CommandDeckView()
            case .workspaces: WorkspacesView()
            case .agents: AgentsView()
            case .terminal: TerminalSectionView()
            case .files: FilesSectionView()
            case .visuals: VisualsView()
            case .git: GitBuildsView()
            case .machines: MachinesView()
            case .settings: SettingsView()
            }
        }
    }
}

/// The full sidebar drawn over the content (narrow iPad windows, and the
/// iPhone's More tab). Closes on a tap outside, a swipe left or navigating.
struct SidebarOverlay: View {
    let width: CGFloat
    @Environment(AppModel.self) private var app
    var body: some View {
        ZStack(alignment: .leading) {
        Color.black.opacity(0.22).ignoresSafeArea()
            .onTapGesture { withAnimation(.snappy(duration: 0.22)) { app.sidebarOverlay = false } }
            .accessibilityLabel(Text("Close sidebar"))
            .transition(.opacity)
        Sidebar(style: .full, compact: true)
            .frame(width: min(300, width - 48))
            .background(Theme.surface.ignoresSafeArea())
            .shadow(color: .black.opacity(0.18), radius: 18, x: 4)
            .transition(.move(edge: .leading))
            .gesture(DragGesture(minimumDistance: 24).onEnded { v in
                if v.translation.width < -50 { withAnimation(.snappy(duration: 0.22)) { app.sidebarOverlay = false } }
            })
        }
    }
}

struct Sidebar: View {
    enum Style { case full, rail }
    let style: Style
    var compact = false
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: style == .full ? .leading : .center, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(AppSection.allCases) { s in
                        SidebarRow(section: s, selected: app.section == s && app.studioAgent == nil, badge: badge(for: s), rail: style == .rail) { navigate { app.go(s) } }
                    }
                    SidebarAgents(rail: style == .rail) { f in navigate(f) }
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
            newTask
        }
        .background(Theme.surface)
    }

    @ViewBuilder var header: some View {
        if style == .full {
            HStack(spacing: 9) {
                Image("SidebarMark").resizable().frame(width: 24, height: 24).clipShape(RoundedRectangle(cornerRadius: 6))
                MachineSwitcher()
                Spacer(minLength: 0)
                IconButton(systemName: "sidebar.left", help: compact ? "Close sidebar" : "Collapse sidebar (⌃⌘S)") { toggle() }
                    .accessibilityIdentifier("sidebar.toggle")
            }
            .padding(.leading, 14).padding(.trailing, 6).padding(.top, 10).padding(.bottom, 8)
        } else {
            VStack(spacing: 6) {
                IconButton(systemName: "sidebar.left", help: "Show sidebar (⌃⌘S)") { toggle() }
                    .accessibilityIdentifier("sidebar.toggle")
                ConnectionDot()
            }
            .padding(.top, 10).padding(.bottom, 6)
        }
    }

    @ViewBuilder var newTask: some View {
        Button { app.launcherProject = app.workspaceProject; app.showLauncher = true; if compact { app.sidebarOverlay = false } } label: {
            Group {
                if style == .full { Label("New agent task", systemImage: "plus").font(.system(size: 13.5, weight: .semibold)).frame(maxWidth: .infinity) }
                else { Image(systemName: "plus").font(.system(size: 15, weight: .semibold)).frame(width: 40) }
            }
            .frame(height: 38)
            .background(Theme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 9))
            .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain).padding(style == .full ? 12 : 10)
        .help("New agent task (⇧⌘N)")
        .accessibilityLabel(Text("New agent task"))
    }

    func toggle() {
        withAnimation(.snappy(duration: 0.22)) {
            if compact { app.sidebarOverlay.toggle() } else { app.sidebarExpanded.toggle() }
        }
    }

    func navigate(_ f: () -> Void) {
        f()
        if compact { withAnimation(.snappy(duration: 0.22)) { app.sidebarOverlay = false } }
    }

    func badge(for s: AppSection) -> Int {
        switch s {
        case .agents: return app.agents.filter { $0.status == "approval" }.count
        default: return 0
        }
    }
}

struct SidebarRow: View {
    let section: AppSection
    let selected: Bool
    let badge: Int
    var rail = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Group {
                if rail {
                    Image(systemName: section.icon).font(.system(size: 16, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Theme.accent : Theme.textDim)
                        .frame(width: 44, height: 40)
                        .background(selected ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 9))
                        .overlay(alignment: .topTrailing) {
                            if badge > 0 { Text("\(badge)").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.onAccent).padding(.horizontal, 4.5).padding(.vertical, 1).background(Theme.yellow, in: Capsule()).offset(x: 2, y: -1) }
                        }
                        .frame(maxWidth: .infinity)
                } else {
                    HStack(spacing: 11) {
                        Image(systemName: section.icon).font(.system(size: 14, weight: .medium)).frame(width: 20)
                            .foregroundStyle(selected ? Theme.accent : Theme.textDim)
                        Text(section.title).font(.system(size: 14, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Theme.text : Theme.textDim)
                        Spacer()
                        if badge > 0 {
                            Text("\(badge)").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.onAccent)
                                .padding(.horizontal, 7).padding(.vertical, 1).background(Theme.yellow, in: Capsule())
                        }
                    }
                    .padding(.horizontal, 12).frame(height: 38)
                    .background(selected ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 9))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, rail ? 0 : 8)
        .hoverEffect(.highlight)
        .help(section.title)
        .accessibilityLabel(Text(badge > 0 ? "\(section.title), \(badge) waiting" : section.title))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("sidebar.\(section.rawValue)")
    }
}

struct ConnectionDot: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let info: (status: String, label: String) = {
            switch (app.phase, app.streamState) {
            case (.ready, .live): return ("idle", "Live")
            case (.ready, .retrying), (.connecting, _): return ("approval", "Reconnecting")
            case (.offline, _): return ("failed", "Offline")
            default: return ("other", "Connecting")
            }
        }()
        StatusDot(status: info.status, size: 7).help(info.label).accessibilityLabel(Text(info.label))
    }
}

struct OfflineBar: View {
    @Environment(AppModel.self) private var app
    let message: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
            Text("Can't reach the gateway — \(message). Agents keep running on the server; retrying automatically.").lineLimit(2)
            Spacer()
            Button("Retry") { Task { await app.connect() } }.font(Theme.label)
        }
        .font(Theme.caption).foregroundStyle(Theme.text)
        .padding(.horizontal, 14).frame(minHeight: 34).background(Theme.red.opacity(0.14))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

struct EventBanner: View {
    @Environment(AppModel.self) private var app
    let event: TimelineEvent
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: event.icon).foregroundStyle(Theme.status(event.tint))
            Text(event.title).font(Theme.label).lineLimit(2)
            Spacer()
            if event.session != nil { Button("Open") { if let s = event.session { app.openAgent(s) }; app.banner = nil }.font(Theme.label) }
            IconButton(systemName: "xmark", help: "Dismiss") { app.banner = nil }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.lineStrong))
        .frame(maxWidth: 560).padding(.top, 10)
        .task(id: event.stableId) { try? await Task.sleep(nanoseconds: 6_000_000_000); if app.banner?.stableId == event.stableId { app.banner = nil } }
    }
}

/// Sidebar title: the active computer, with every saved one a tap away.
struct MachineSwitcher: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        Menu {
            ForEach(app.machines) { m in
                Button { Task { await app.activate(m) } } label: {
                    if m.id == app.activeMachine?.id { Label(m.name, systemImage: "checkmark") } else { Label(m.name, systemImage: m.symbol) }
                }
            }
            Divider()
            Button { app.showAddMachine = true; app.go(.machines) } label: { Label("Add a computer…", systemImage: "plus") }
            Button { app.go(.machines) } label: { Label("Machines & AI", systemImage: "desktopcomputer") }
        } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(app.activeMachine?.name ?? "Musa Control").font(.system(size: 14.5, weight: .semibold)).lineLimit(1).foregroundStyle(Theme.text)
                    Text(app.activeMachine?.kindLabel ?? "").font(.system(size: 11)).foregroundStyle(Theme.textFaint).lineLimit(1)
                }
                ConnectionDot()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textFaint)
            }
        }
        .accessibilityIdentifier("machine.switcher")
    }
}
