import SwiftUI

enum StudioPanel: String, CaseIterable, Identifiable {
    case overview, agents, liveWork
    var id: Self { self }
    var title: String {
        switch self {
        case .overview: return "Overview"
        case .agents: return "Agents"
        case .liveWork: return "Live Work"
        }
    }
}

struct StudioDashboard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            HStack {
                Text("Studio").font(.title2.weight(.semibold)).foregroundStyle(Theme.text)
                Spacer()
                ProjectPicker(selection: $app.studioProject)
                Menu {
                    if let id = app.studioProject {
                        Button { app.studioFiles = ProjectSheetItem(id: id) } label: { Label("Find or edit files", systemImage: "magnifyingglass") }
                        Button { app.openGitBuilds(project: id) } label: { Label("Git & Builds", systemImage: "arrow.triangle.branch") }
                    }
                    Button { app.showDesktop(follow: false) } label: { Label("Remote Desktop", systemImage: "display") }
                    Button {
                        app.launcherProject = app.studioProject
                        app.showLauncher = true
                    } label: { Label("New agent task", systemImage: "plus") }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3).frame(width: 34, height: 34)
                }
                .accessibilityLabel("Studio actions")
            }
            .padding(.horizontal, 16).padding(.top, 10)
            Picker("Studio workspace", selection: $app.studioPanel) {
                ForEach(StudioPanel.allCases) { panel in
                    Text(panel.title).tag(panel)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("studio.workspace")
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            switch app.studioPanel {
            case .overview: StudioOverview()
            case .agents: AgentsView()
            case .liveWork: LiveWorkPanel()
            }
        }
        .background(Theme.bg)
        .task(id: app.activeMachine?.id) {
            if app.studioProject == nil { app.studioProject = app.workspaceProject ?? app.projects.first?.id }
        }
        .onChange(of: app.projects.map(\.id)) { _, ids in
            if app.studioProject == nil { app.studioProject = ids.first }
        }
    }
}

private struct StudioFile: Identifiable {
    let project: String
    let path: String
    var id: String { project + "/" + path }
}

private struct StudioOverview: View {
    @Environment(AppModel.self) private var app
    @State private var files = FilesState.shared
    @State private var selectedScreenshot: Screenshot?
    @State private var showProjects = false

    private var edits: [StudioFile] {
        let history = Array(app.liveEvents.suffix(100).reversed()) + Array((app.overview?.recent ?? []).reversed())
        var seen: Set<String> = []
        return history.compactMap { event in
            guard ["file.changed", "file.saved", "agent.edit"].contains(event.kind),
                  let project = event.project,
                  let name = event.detail?["path"]?.string,
                  let relative = filePath(project, name) else { return nil }
            let item = StudioFile(project: project, path: relative)
            return seen.insert(item.id).inserted ? item : nil
        }
    }

    private func filePath(_ project: String, _ name: String) -> String? {
        if !name.hasPrefix("/") { return name.isEmpty ? nil : name }
        guard let root = app.project(project)?.path, name.hasPrefix(root + "/") else { return nil }
        return String(name.dropFirst(root.count + 1))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let system = app.overview?.system { resources(system) }
                activeWork
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 310), alignment: .top)], alignment: .leading, spacing: 16) {
                    filesCard
                    buildsCard
                }
                if let images = app.overview?.screenshots, !images.isEmpty { screenshots(images) }
                projectsCard
            }
            .frame(maxWidth: 1100)
            .padding(16)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("studio.overview")
        .refreshable { await app.refreshAll() }
        .task(id: app.activeMachine?.id) {
            while !Task.isCancelled {
                await app.refreshOverview()
                try? await Task.sleep(for: .seconds(24))
            }
        }
        .sheet(item: $selectedScreenshot) { shot in
            NavigationStack {
                AuthImage(path: "/api/screenshots/\(shot.id)/image")
                    .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.bg)
                    .navigationTitle(shot.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { selectedScreenshot = nil } }
                    }
            }
        }
    }

    private func resources(_ system: SystemSummary) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(system.healthy ? "Server healthy" : "Server needs attention", systemImage: system.healthy ? "checkmark.circle" : "exclamationmark.triangle")
                .font(Theme.label)
                .foregroundStyle(system.healthy ? Theme.green : Theme.yellow)
            Text("Memory \(bytes(system.memory.available)) free  ·  Disk \(bytes(system.disk.available)) free  ·  Load \(system.load.first ?? 0, specifier: "%.1f")")
                .font(Theme.caption).foregroundStyle(Theme.textDim)
            ForEach(Array(system.issues.prefix(2)), id: \.self) { Text($0).font(Theme.caption).foregroundStyle(Theme.yellow) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var activeWork: some View {
        let active = app.agents.filter { $0.isLive || $0.status == "approval" }
        return studioCard("Active work") {
            if active.isEmpty { Text("No active agents").font(Theme.caption).foregroundStyle(Theme.textDim) }
            ForEach(Array(active.sorted { ($0.status == "approval" ? 0 : 1) < ($1.status == "approval" ? 0 : 1) }.prefix(4))) { agent in
                Button { app.showAgent(agent.id) } label: { AgentRow(agent: agent) }.buttonStyle(.plain)
            }
            HStack {
                Button("All agents") { app.studioPanel = .agents }
                Spacer()
                Button { app.studioPanel = .liveWork } label: { Label("Live Work", systemImage: "display") }
            }
            .font(Theme.label)
        }
    }

    private var filesCard: some View {
        studioCard("Files") {
            if let id = app.studioProject {
                Button { app.studioFiles = ProjectSheetItem(id: id) } label: { Label("Find or edit files", systemImage: "magnifyingglass") }
                    .accessibilityIdentifier("studio.files")
                let opened = files.recentPaths[id] ?? files.openPath[id].map { [$0] } ?? []
                ForEach(Array(opened.prefix(3)), id: \.self) { path in
                    fileButton(StudioFile(project: id, path: path), icon: "clock")
                }
            }
            ForEach(Array(edits.filter { !(files.recentPaths[$0.project] ?? []).contains($0.path) && files.openPath[$0.project] != $0.path }.prefix(4))) { item in
                fileButton(item, icon: "pencil.line")
            }
        }
    }

    private func fileButton(_ item: StudioFile, icon: String) -> some View {
        Button { app.openFile(project: item.project, path: item.path) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Label((item.path as NSString).lastPathComponent, systemImage: icon).lineLimit(1)
                if let project = app.project(item.project) { Text(project.name).font(Theme.caption).foregroundStyle(Theme.textDim) }
            }
        }
        .buttonStyle(.plain)
    }

    private var buildsCard: some View {
        studioCard("Builds & changes") {
            ForEach(Array((app.overview?.builds ?? []).prefix(3))) { build in
                Button { app.openGitBuilds(project: build.project) } label: {
                    HStack {
                        Text(build.label).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(build.status.capitalized).font(Theme.caption).foregroundStyle(Theme.textDim)
                    }
                }.buttonStyle(.plain)
            }
            ForEach(Array((app.overview?.recent ?? []).reversed().filter { $0.kind.hasPrefix("git.") || $0.kind == "ci.finished" }.prefix(3)), id: \.stableId) { event in
                Button { app.openGitBuilds(project: event.project) } label: { Label(event.title, systemImage: event.icon).lineLimit(1) }
                    .buttonStyle(.plain)
            }
            if let id = app.studioProject {
                Button { app.openGitBuilds(project: id) } label: { Label("Open Git & Builds", systemImage: "arrow.triangle.branch") }
                    .accessibilityIdentifier("studio.builds")
            }
        }
    }

    private func screenshots(_ shots: [Screenshot]) -> some View {
        studioCard("Recent visuals") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(shots.prefix(8))) { shot in
                        Button { selectedScreenshot = shot } label: {
                            AuthImage(path: "/api/screenshots/\(shot.id)/image", query: ["w": "320"], contentMode: .fill)
                                .frame(width: 150, height: 94)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).accessibilityLabel(shot.name)
                    }
                }
            }
        }
    }

    private var projectsCard: some View {
        studioCard("Projects") {
            DisclosureGroup(isExpanded: $showProjects) {
                ForEach(app.projects) { project in
                    Button {
                        app.studioProject = project.id
                        app.studioFiles = ProjectSheetItem(id: project.id)
                    } label: {
                        HStack {
                            Label(project.name, systemImage: project.icon)
                            Spacer(minLength: 8)
                            if let version = project.version { Text(version).font(Theme.caption).foregroundStyle(Theme.textDim) }
                            if let count = project.activeAgents, count > 0 { Text("\(count) active").font(Theme.caption).foregroundStyle(Theme.accent) }
                        }.padding(.vertical, 5)
                    }.buttonStyle(.plain)
                }
            } label: { Text("\(app.projects.count) on this machine").foregroundStyle(Theme.textDim) }
        }
    }

    private func studioCard<Content: View>(_ name: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(name).font(.headline)
            content()
        }
        .padding(14)
        .foregroundStyle(Theme.text)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func bytes(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, value)), countStyle: .memory)
    }
}

struct StudioFilesSheet: View {
    let projectId: String
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var files = FilesState.shared
    @State private var showEditor = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(app.project(projectId)?.name ?? "Files").font(Theme.title)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding().background(Theme.surface)
            Divider()
            AdaptiveSplit(masterWidth: 310, showingDetail: showEditor, backTitle: "Find files",
                          onBack: { showEditor = false }) {
                FileBrowser(projectId: projectId) { showEditor = true }
            } detail: {
                FileViewerPanel(projectId: projectId)
            }
        }
        .background(Theme.bg)
        .task {
            showEditor = files.openPath[projectId] != nil
            _ = try? await app.client.send("POST", "/api/projects/\(projectId.pathSegment)/watch", ["minutes": 60], as: WatchState.self)
        }
        .frame(minWidth: Device.isPhone ? nil : 680, minHeight: Device.isPhone ? nil : 590)
    }
}
