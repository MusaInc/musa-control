import SwiftUI

/// Simplified native shell: Agents at the centre, with Terminal, Files and
/// Settings. Git, builds, remote desktop and visualisations open contextually
/// from the conversation or file browser rather than cluttering navigation.
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
                PadShell()
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .overlay(alignment: .top) {
            if let b = app.banner {
                EventBanner(event: b).transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: app.banner?.stableId)
        .sheet(item: $app.sheet) { s in SheetHost(sheet: s) }
        .sheet(item: $app.gitBuildsSheet) { item in ProjectGitBuildsSheet(projectId: item.id) }
        .sheet(isPresented: $app.showLauncher) { AgentLauncher(initialProject: app.launcherProject) }
        .sheet(isPresented: $app.showSwitcher) { QuickSwitcher() }
        .sheet(isPresented: $app.showQuickOpen) { QuickOpenSheet() }
        .fullScreenCover(isPresented: $app.showFullScreenDesktop) {
            FullScreenDesktopCover()
        }
    }
}

/// iPad shell: clean Apple-inspired navigation rail (expands to a compact
/// sidebar when desired on wide screens, stays a slim 56pt rail in Split View
/// and Slide Over) beside the active section.
struct PadShell: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.width < 700
            let expanded = app.sidebarExpanded && !compact
            HStack(spacing: 0) {
                NavigationRail(expanded: expanded, canExpand: !compact)
                    .frame(width: expanded ? 188 : 56)
                Rectangle().fill(Theme.line).frame(width: 1).ignoresSafeArea()
                VStack(spacing: 0) {
                    if case .offline(let msg) = app.phase { OfflineBar(message: msg) }
                    SectionContent()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .environment(\.compactLayout, geo.size.width - (expanded ? 189 : 57) < 620)
                }
                .background(Theme.bg)
            }
        }
    }
}

struct NavigationRail: View {
    let expanded: Bool
    let canExpand: Bool
    @Environment(AppModel.self) private var app

    var waitingCount: Int { app.agents.filter { $0.status == "approval" }.count }

    var body: some View {
        VStack(alignment: expanded ? .leading : .center, spacing: 6) {
            HStack(spacing: 8) {
                Image("SidebarMark")
                    .resizable()
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                if expanded {
                    Text("Musa Control")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, expanded ? 12 : 0)
            .padding(.top, 12)
            .padding(.bottom, 6)

            ForEach(AppSection.allCases) { section in
                railItem(section)
            }

            Spacer(minLength: 12)

            if canExpand {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { app.sidebarExpanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: expanded ? "sidebar.left" : "sidebar.squares.left")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 22)
                        if expanded {
                            Text("Collapse").font(.system(size: 12.5))
                            Spacer(minLength: 0)
                        }
                    }
                    .foregroundStyle(Theme.textFaint)
                    .padding(.horizontal, expanded ? 10 : 0)
                    .frame(width: expanded ? nil : 40, height: 34)
                    .frame(maxWidth: expanded ? .infinity : nil, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "Collapse sidebar" : "Expand sidebar")
                .padding(.horizontal, expanded ? 8 : 0)
            }

            machineButton
                .padding(.horizontal, expanded ? 8 : 0)
                .padding(.bottom, 10)
        }
        .frame(maxHeight: .infinity)
        .background(Theme.surface)
    }

    func railItem(_ section: AppSection) -> some View {
        let selected = app.section == section
        let badge = section == .agents ? waitingCount : 0
        return Button {
            app.go(section)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .font(.system(size: 16, weight: selected ? .semibold : .regular))
                    .frame(width: 22)
                    .overlay(alignment: .topTrailing) {
                        if badge > 0 && !expanded {
                            Text("\(badge)")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(Theme.onAccent)
                                .padding(.horizontal, 4)
                                .background(Theme.yellow, in: Capsule())
                                .offset(x: 8, y: -6)
                        }
                    }
                if expanded {
                    Text(section.title)
                        .font(.system(size: 14, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if badge > 0 {
                        Text("\(badge)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Theme.yellow, in: Capsule())
                    }
                }
            }
            .foregroundStyle(selected ? Theme.accent : Theme.textDim)
            .padding(.horizontal, expanded ? 10 : 0)
            .frame(width: expanded ? nil : 40, height: 38)
            .frame(maxWidth: expanded ? .infinity : nil, alignment: .leading)
            .background(selected ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .help(section.title)
        .accessibilityLabel(Text(badge > 0 ? "\(section.title), \(badge) waiting" : section.title))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("nav.\(section.rawValue)")
        .padding(.horizontal, expanded ? 8 : 0)
    }

    var machineButton: some View {
        Button { app.sheet = .machines } label: {
            HStack(spacing: 8) {
                ConnectionDot()
                if expanded {
                    Text(app.activeMachine?.name ?? "Computers")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, expanded ? 10 : 0)
            .frame(width: expanded ? nil : 40, height: 34)
            .frame(maxWidth: expanded ? .infinity : nil, alignment: .leading)
            .background(Theme.hover.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Machines & AI accounts")
        .accessibilityLabel(Text("Machines & AI accounts"))
        .accessibilityIdentifier("machine.switcher")
    }
}

struct SectionContent: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        switch app.section {
        case .agents: AgentsView()
        case .terminal: TerminalSectionView()
        case .files: FilesSectionView()
        case .settings: SettingsView()
        }
    }
}

/// Full-screen interactive Remote Desktop cover (opened from an inline desktop
/// preview in the conversation or via ⌃⌘D).
struct FullScreenDesktopCover: View {
    @Environment(AppModel.self) private var app
    @Environment(DesktopStore.self) private var desk
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                StatusDot(status: desk.connected ? "idle" : "approval", size: 7)
                Text(desk.currentDisplay?.label ?? "Remote Desktop :\(desk.display)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Button("Done") {
                    app.showFullScreenDesktop = false
                    dismiss()
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(Theme.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }

            DesktopPane(chrome: .full)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(Theme.terminalBg))
        .onAppear {
            if !desk.active { desk.open(client: app.client, machine: app.activeMachine?.id, presentation: .full) }
        }
    }
}

/// Contextual Git & Builds sheet for a specific project (opened from an agent
/// conversation or from Files).
struct ProjectGitBuildsSheet: View {
    let projectId: String
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var tab = "changes"

    var project: Project? { app.project(projectId) }

    var tabs: [(value: String, title: String)] {
        var t: [(value: String, title: String)] = [("changes", "Changes"), ("builds", "Builds"), ("history", "History"), ("branches", "Branches")]
        if project?.github != nil { t += [("ci", "Actions"), ("prs", "PRs")] }
        return t
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: project?.icon ?? "folder").foregroundStyle(Theme.accent)
                Text(project?.name ?? projectId).font(Theme.title)
                Text("Git & Builds").font(Theme.caption).foregroundStyle(Theme.textFaint)
                Spacer()
                Button("Done") { dismiss() }.font(Theme.label).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16).frame(height: 48).background(Theme.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }

            ChipPicker(options: tabs, selection: $tab).background(Theme.raised)

            Group {
                switch tab {
                case "history": GitHistory(projectId: projectId)
                case "branches": GitBranches(projectId: projectId)
                case "builds": BuildsPanel(projectId: projectId)
                case "ci": if let r = project?.github { CIRuns(repo: r) }
                case "prs": if let r = project?.github { PullRequests(repo: r) }
                default: GitPanel(projectId: projectId)
                }
            }
            .id("\(projectId)/\(tab)")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.bg)
        .frame(minWidth: Device.isPhone ? nil : 720, minHeight: Device.isPhone ? nil : 620)
    }
}

/// Machines & AI (and Settings when opened as a sheet).
struct SheetHost: View {
    let sheet: AppSheet
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(sheet == .machines ? "Machines & AI" : "Settings").font(Theme.title)
                Spacer()
                Button("Done") { dismiss() }.font(Theme.label).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16).frame(height: 48).background(Theme.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
            Group {
                switch sheet {
                case .machines: MachinesView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.bg)
        .frame(minWidth: Device.isPhone ? nil : 640, minHeight: Device.isPhone ? nil : 620)
    }
}

/// ⌘P: find a file in the current project and open it in Files.
struct QuickOpenSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Open file").font(Theme.title)
                Spacer()
                Button("Done") { dismiss() }.font(Theme.label)
            }
            .padding(.horizontal, 16).frame(height: 48)
            if let p = app.agent(app.focusedAgent)?.project ?? app.filesProject ?? app.projects.first?.id {
                FileBrowser(projectId: p, onOpen: { app.filesProject = p; app.section = .files; dismiss() })
            } else { EmptyNote(icon: "folder", text: "No project available") }
        }
        .frame(minWidth: Device.isPhone ? nil : 560, minHeight: Device.isPhone ? nil : 560)
        .background(Theme.surface)
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
