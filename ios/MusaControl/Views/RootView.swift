import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var app = app
        Group {
            if app.phase == .unpaired {
                PairingView()
            } else {
                NavigationSplitView(columnVisibility: $columns) {
                    Sidebar()
                        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
                } detail: {
                    VStack(spacing: 0) {
                        if case .offline(let msg) = app.phase { OfflineBar(message: msg) }
                        detail
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .background(Theme.bg)
                    .toolbar(.hidden, for: .navigationBar)
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .overlay(alignment: .top) { if let b = app.banner { EventBanner(event: b).transition(.move(edge: .top).combined(with: .opacity)) } }
        .animation(.spring(duration: 0.35), value: app.banner?.stableId)
        .sheet(isPresented: $app.showLauncher) { AgentLauncher(initialProject: app.launcherProject) }
        .sheet(isPresented: $app.showSwitcher) { QuickSwitcher() }
    }

    @ViewBuilder private var detail: some View {
        switch app.section {
        case .home: HomeView()
        case .workspaces: WorkspacesView()
        case .agents: AgentsView()
        case .terminal: TerminalSectionView()
        case .files: FilesSectionView()
        case .visuals: VisualsView()
        case .git: GitBuildsView()
        case .settings: SettingsView()
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image("SidebarMark").resizable().frame(width: 22, height: 22).clipShape(RoundedRectangle(cornerRadius: 5))
                Text("Musa Control").font(.system(size: 14, weight: .semibold))
                Spacer()
                ConnectionDot()
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(AppSection.allCases) { s in
                        SidebarRow(section: s, selected: app.section == s, badge: badge(for: s)) { app.go(s) }
                    }
                    if !activeProjects.isEmpty {
                        SectionHeader(title: "Active").padding(.top, 8)
                        ForEach(activeProjects) { p in
                            Button { app.openWorkspace(p.id) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: p.icon).font(.system(size: 11)).frame(width: 16).foregroundStyle(Theme.textDim)
                                    Text(p.name).font(.system(size: 12.5)).lineLimit(1)
                                    Spacer()
                                    StatusDot(status: "working", size: 6)
                                }
                                .padding(.horizontal, 12).frame(height: 30).contentShape(Rectangle())
                                .background(app.section == .workspaces && app.workspaceProject == p.id ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain).padding(.horizontal, 6)
                        }
                    }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
            Button { app.launcherProject = app.workspaceProject; app.showLauncher = true } label: {
                Label("New agent task", systemImage: "plus").font(.system(size: 12.5, weight: .medium))
                    .frame(maxWidth: .infinity).frame(height: 34)
                    .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain).padding(12)
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        .background(Theme.surface)
    }

    var activeProjects: [Project] { app.projects.filter { ($0.activeAgents ?? 0) > 0 }.prefix(6).map { $0 } }

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
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.icon).font(.system(size: 13, weight: .medium)).frame(width: 18)
                    .foregroundStyle(selected ? Theme.accent : Theme.textDim)
                Text(section.title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.text : Theme.textDim)
                Spacer()
                if badge > 0 {
                    Text("\(badge)").font(.system(size: 10.5, weight: .bold)).foregroundStyle(.black)
                        .padding(.horizontal, 6).padding(.vertical, 1).background(Theme.yellow, in: Capsule())
                }
            }
            .padding(.horizontal, 12).frame(height: 34).contentShape(Rectangle())
            .background(selected ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .hoverEffect(.highlight)
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
            Text("Can't reach the gateway — \(message). Your agents and sessions keep running on the server.").lineLimit(1)
            Spacer()
            Button("Retry") { Task { await app.connect() } }.font(Theme.label)
        }
        .font(Theme.caption).foregroundStyle(Theme.text)
        .padding(.horizontal, 14).frame(height: 32).background(Theme.red.opacity(0.18))
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
