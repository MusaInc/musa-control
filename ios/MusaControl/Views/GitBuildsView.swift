import SwiftUI

struct GitBuildsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.compactLayout) private var compact
    @State private var project: String?
    @State private var tab = "changes"

    var gitProjects: [Project] { app.projects.filter { $0.git } }

    var body: some View {
        HStack(spacing: 0) {
            if !compact {
                VStack(spacing: 0) {
                    PanelHeader(icon: "arrow.triangle.branch", title: "Repositories", subtitle: "\(gitProjects.count)")
                    List(gitProjects, selection: $project) { p in
                        HStack(spacing: 8) {
                            Image(systemName: p.icon).frame(width: 16).foregroundStyle(Theme.textDim)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.name).font(.system(size: 14))
                                Text(p.github ?? "local only").font(.system(size: 12)).foregroundStyle(Theme.textFaint)
                            }
                        }
                        .tag(p.id).listRowBackground(project == p.id ? Theme.hover : Theme.surface)
                    }
                    .listStyle(.plain).scrollContentBackground(.hidden)
                }
                .frame(width: 250).background(Theme.surface)
                Divider().overlay(Theme.line)
            }
            VStack(spacing: 0) {
                if compact { repoMenu }
                if let id = project, let p = app.project(id) {
                    ChipPicker(options: tabs(p), selection: $tab).background(Theme.raised)
                    Group {
                        switch tab {
                        case "history": GitHistory(projectId: id)
                        case "branches": GitBranches(projectId: id)
                        case "builds": BuildsPanel(projectId: id)
                        case "ci": if let r = p.github { CIRuns(repo: r) }
                        case "prs": if let r = p.github { PullRequests(repo: r) }
                        default: GitPanel(projectId: id)
                        }
                    }
                    .id("\(id)/\(tab)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else { EmptyNote(icon: "arrow.triangle.branch", text: "Choose a repository") }
            }
        }
        .background(Theme.bg)
        .onAppear { pickDefault() }
        .onChange(of: app.projects.count) { _, _ in pickDefault() }
        .onChange(of: project) { _, id in if let p = app.project(id), p.github == nil, tab == "ci" || tab == "prs" { tab = "changes" } }
    }

    /// The current workspace's repo, else the first; also once projects load late.
    func pickDefault() {
        guard project == nil else { return }
        project = app.workspaceProject.flatMap { id in gitProjects.contains { $0.id == id } ? id : nil } ?? gitProjects.first?.id
    }

    func tabs(_ p: Project) -> [(value: String, title: String)] {
        var t: [(value: String, title: String)] = [("changes", "Changes"), ("history", "History"), ("branches", "Branches"), ("builds", "Builds")]
        if p.github != nil { t += [("ci", "Actions"), ("prs", "Pull requests")] }
        return t
    }

    var repoMenu: some View {
        Menu {
            ForEach(gitProjects) { p in Button { project = p.id } label: { Label(p.name, systemImage: p.id == project ? "checkmark" : p.icon) } }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(Theme.textDim)
                VStack(alignment: .leading, spacing: 0) {
                    Text(app.project(project)?.name ?? "Choose a repository").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(app.project(project)?.github ?? "local only").font(.system(size: 12)).foregroundStyle(Theme.textFaint)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 12)).foregroundStyle(Theme.textDim)
            }
            .padding(.horizontal, 14).frame(height: 50).background(Theme.surface)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .accessibilityIdentifier("git.repoMenu")
    }
}

/// Working tree: stage, diff, commit, push/pull (confirmed).
struct GitPanel: View {
    let projectId: String
    @Environment(AppModel.self) private var app
    @State private var status: GitStatus?
    @State private var selected: GitFile?
    @State private var diff = ""
    @State private var message = ""
    @State private var busy = false
    @State private var note: String?
    @State private var confirm: String?

    var body: some View {
        AdaptiveSplit(masterWidth: 320, showingDetail: selected != nil, backTitle: "Changes", onBack: { selected = nil; diff = "" }) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(Theme.textDim)
                    Text(status?.branch ?? "—").font(Theme.label)
                    if let a = status?.ahead, a > 0 { Pill(text: "↑\(a)", color: Theme.blue) }
                    if let b = status?.behind, b > 0 { Pill(text: "↓\(b)", color: Theme.yellow) }
                    Spacer()
                    IconButton(systemName: "arrow.down.circle", help: "Pull (fast-forward)") { confirm = "pull" }
                    IconButton(systemName: "arrow.up.circle", help: "Push") { confirm = "push" }
                    IconButton(systemName: "arrow.clockwise", help: "Refresh") { Task { await load() } }
                }
                .padding(.horizontal, 10).frame(height: 36).background(Theme.raised)
                List {
                    let files = status?.files ?? []
                    let staged = files.filter { $0.staged }
                    let unstaged = files.filter { $0.unstaged }
                    if !staged.isEmpty { SwiftUI.Section("Staged") { ForEach(staged) { f in fileRow(f, staged: true) } } }
                    SwiftUI.Section("Changes") { ForEach(unstaged) { f in fileRow(f, staged: false) } }
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
                .overlay { if status?.files?.isEmpty == true { EmptyNote(icon: "checkmark.seal", text: "Working tree clean") } }
                VStack(spacing: 6) {
                    TextField("Commit message", text: $message, axis: .vertical).lineLimit(1...4).font(.system(size: 14))
                        .padding(8).background(Theme.bg, in: RoundedRectangle(cornerRadius: 7))
                    Button { commit() } label: {
                        Text(busy ? "Working…" : "Commit staged").font(Theme.label).frame(maxWidth: .infinity).frame(height: 32)
                            .background(canCommit ? Theme.accent : Theme.hover, in: RoundedRectangle(cornerRadius: 7)).foregroundStyle(canCommit ? .black : Theme.textFaint)
                    }.buttonStyle(.plain).disabled(!canCommit)
                    if let note { Text(note).font(Theme.caption).foregroundStyle(Theme.textDim).lineLimit(4) }
                }
                .padding(8).background(Theme.raised)
            }
            .background(Theme.surface)
        } detail: {
            DiffView(diff: diff, emptyText: selected == nil ? "Choose a file to see its diff" : "No textual changes")
        }
        .task(id: projectId) { await load() }
        .onChange(of: app.eventTick) { _, _ in if let e = app.liveEvents.last, e.project == projectId, e.kind == "file.changed" { Task { await load(); if let s = selected { await showDiff(s) } } } }
        .confirmationDialog(confirm == "push" ? "Push \(status?.branch ?? "") to \(status?.upstream ?? "origin")?" : "Pull \(status?.upstream ?? "")?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
            Button(confirm == "push" ? "Push" : "Pull (fast-forward only)") {
                let what = confirm ?? ""
                Task {
                    busy = true; defer { busy = false }
                    do {
                        let r = try await app.client.send("POST", "/api/projects/\(projectId)/git/\(what)", ["confirm": true], as: [String: JSONValue].self, timeout: 150)
                        note = r["output"]?.string ?? "Done"
                    } catch { note = error.localizedDescription }
                    await load()
                }
            }
        } message: { Text(confirm == "push" ? "This publishes your commits to GitHub." : "Only fast-forward merges are performed; nothing is overwritten.") }
    }

    var canCommit: Bool { !busy && !message.trimmingCharacters(in: .whitespaces).isEmpty && (status?.files?.contains { $0.staged } ?? false) }

    func fileRow(_ f: GitFile, staged: Bool) -> some View {
        HStack(spacing: 8) {
            Button { toggle(f, staged: staged) } label: { Image(systemName: staged ? "checkmark.square.fill" : "square").foregroundStyle(staged ? Theme.accent : Theme.textDim).frame(width: 26, height: 26) }.buttonStyle(.plain)
            Text(f.code).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(f.code == "?" || f.code == "A" ? Theme.green : f.code == "D" ? Theme.red : Theme.yellow).frame(width: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text((f.path as NSString).lastPathComponent).font(.system(size: 13.5)).lineLimit(1)
                Text((f.path as NSString).deletingLastPathComponent).font(.system(size: 11.5)).foregroundStyle(Theme.textFaint).lineLimit(1)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { selected = f; Task { await showDiff(f, staged: staged) } }
        .listRowBackground(selected?.path == f.path ? Theme.hover : Theme.surface)
        .contextMenu {
            Button { FilesState.shared.open(project: projectId, path: f.path); app.filesProject = projectId; app.go(.files) } label: { Label("Open file", systemImage: "doc.text") }
        }
    }

    func load() async { status = try? await app.client.get("/api/projects/\(projectId)/git/status", as: GitStatus.self) }
    func showDiff(_ f: GitFile, staged: Bool? = nil) async {
        diff = (try? await app.client.get("/api/projects/\(projectId)/git/diff", ["file": f.path, "staged": (staged ?? f.staged) ? "1" : nil], as: DiffResponse.self).diff) ?? ""
    }
    func toggle(_ f: GitFile, staged: Bool) {
        Task {
            _ = try? await app.client.send("POST", "/api/projects/\(projectId)/git/\(staged ? "unstage" : "stage")", ["paths": [f.path]], as: GitStatus.self)
            await load()
        }
    }
    func commit() {
        busy = true
        Task {
            defer { busy = false }
            do { let c = try await app.client.send("POST", "/api/projects/\(projectId)/git/commit", ["message": message], as: Commit.self); note = "Committed \(c.short)"; message = "" }
            catch { note = error.localizedDescription }
            await load()
        }
    }
}

struct GitHistory: View {
    let projectId: String
    @Environment(AppModel.self) private var app
    @State private var commits: [Commit] = []
    @State private var selected: String?
    @State private var diff = ""
    var body: some View {
        AdaptiveSplit(masterWidth: 340, showingDetail: selected != nil, backTitle: "History", onBack: { selected = nil; diff = "" }) {
            List(commits, selection: $selected) { c in
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.subject).font(.system(size: 13.5)).lineLimit(2)
                    HStack(spacing: 6) { Text(c.short).font(Theme.monoSmall).foregroundStyle(Theme.accent); Text(c.author); Text(String(c.date.prefix(16)).replacingOccurrences(of: "T", with: " ")) }
                        .font(.system(size: 12)).foregroundStyle(Theme.textFaint)
                }
                .tag(c.sha).listRowBackground(selected == c.sha ? Theme.hover : Theme.surface)
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
        } detail: {
            DiffView(diff: diff, emptyText: "Choose a commit")
        }
        .task(id: projectId) { commits = (try? await app.client.get("/api/projects/\(projectId)/git/log", ["limit": "100"], as: [Commit].self)) ?? [] }
        .task(id: selected) { if let s = selected { diff = (try? await app.client.get("/api/projects/\(projectId)/git/diff", ["commit": s], as: DiffResponse.self).diff) ?? "" } }
    }
}

struct GitBranches: View {
    let projectId: String
    @Environment(AppModel.self) private var app
    @State private var branches: [Branch] = []
    var body: some View {
        List(branches) { b in
            HStack {
                Image(systemName: b.current ? "checkmark.circle.fill" : (b.name.contains("/") ? "cloud" : "arrow.triangle.branch")).foregroundStyle(b.current ? Theme.accent : Theme.textDim)
                Text(b.name).font(.system(size: 14, weight: b.current ? .semibold : .regular))
                if let u = b.upstream, !u.isEmpty { Text("→ \(u)").font(Theme.caption).foregroundStyle(Theme.textFaint) }
                Spacer()
                Text(b.sha).font(Theme.monoSmall).foregroundStyle(Theme.textFaint)
                Text(String((b.date ?? "").prefix(10))).font(Theme.caption).foregroundStyle(Theme.textFaint)
            }
            .listRowBackground(Theme.surface)
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .task(id: projectId) { branches = (try? await app.client.get("/api/projects/\(projectId)/git/branches", as: [Branch].self)) ?? [] }
    }
}

/// Project commands (npm scripts, tools/*.sh, Godot tests) run in tmux on the server.
struct BuildsPanel: View {
    let projectId: String
    @Environment(AppModel.self) private var app
    @State private var detail: ProjectDetail?
    @State private var builds: [Build] = []
    @State private var selected: String?
    @State private var log: BuildLog?
    @State private var error: String?
    @Environment(\.compactLayout) private var compact

    var body: some View {
        AdaptiveSplit(masterWidth: 300, showingDetail: selected != nil, backTitle: "Builds", onBack: { selected = nil; log = nil }) {
            VStack(spacing: 0) {
                List {
                    SwiftUI.Section("Run") {
                        ForEach(detail?.commands ?? []) { c in
                            Button { run(c) } label: { HStack { Image(systemName: "play.fill").font(.system(size: 10.5)).foregroundStyle(Theme.accent); Text(c.label).font(Theme.monoSmall).lineLimit(1) } }
                                .buttonStyle(.plain).listRowBackground(Theme.surface)
                        }
                        if detail?.commands.isEmpty == true { Text("This project defines no scripts.").font(Theme.caption).foregroundStyle(Theme.textFaint) }
                    }
                    SwiftUI.Section("Recent") {
                        ForEach(builds) { b in
                            HStack {
                                StatusDot(status: b.status)
                                VStack(alignment: .leading, spacing: 1) { Text(b.label).font(.system(size: 13.5)).lineLimit(1); Text(b.status == "running" ? "running…" : "\(b.status) · \(Fmt.ago(b.endedAt ?? b.startedAt))").font(.system(size: 12)).foregroundStyle(Theme.textFaint) }
                            }
                            .contentShape(Rectangle()).onTapGesture { selected = b.id }
                            .listRowBackground(selected == b.id ? Theme.hover : Theme.surface)
                        }
                    }
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
                if let error { Text(error).font(Theme.caption).foregroundStyle(Theme.red).padding(6) }
            }
            .background(Theme.surface)
        } detail: {
            VStack(spacing: 0) {
                if let l = log {
                    HStack {
                        StatusDot(status: l.status); Text(l.label).font(Theme.label)
                        if let c = l.exitCode { Pill(text: "exit \(c)", color: c == 0 ? Theme.green : Theme.red) }
                        Spacer()
                        if l.status == "running" { Button("Cancel") { Task { _ = try? await app.client.send("POST", "/api/builds/\(l.id)/cancel", [:], as: Build.self) } }.font(Theme.label).foregroundStyle(Theme.red) }
                        if let t = builds.first(where: { $0.id == l.id })?.tmux { Button("Terminal") { app.attachTerminal(t) }.font(Theme.label) }
                    }
                    .padding(.horizontal, 10).frame(height: 34).background(Theme.raised)
                    LogView(text: l.text)
                } else { EmptyNote(icon: "hammer", text: "Run a command or pick a build") }
            }
        }
        .task(id: projectId) { await load() }
        .task(id: selected) {
            guard let s = selected else { return }
            while !Task.isCancelled {
                log = try? await app.client.get("/api/builds/\(s)", as: BuildLog.self)
                if log?.status != "running" { await load(); break }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
        }
    }

    func load() async {
        detail = try? await app.client.get("/api/projects/\(projectId)", as: ProjectDetail.self)
        builds = (try? await app.client.get("/api/projects/\(projectId)/builds", as: [Build].self)) ?? []
        if selected == nil && !compact { selected = builds.first?.id }
    }
    func run(_ c: ProjectCommand) {
        Task {
            do { let b = try await app.client.send("POST", "/api/projects/\(projectId)/builds", ["commandId": c.id], as: Build.self); error = nil; await load(); selected = b.id }
            catch { self.error = error.localizedDescription }
        }
    }
}

/// Monospaced log that follows the tail, with error lines highlighted.
struct LogView: View {
    let text: String
    var body: some View {
        ScrollViewReader { p in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                        Text(l.isEmpty ? " " : l).font(Theme.monoSmall)
                            .foregroundStyle(l.range(of: #"(?i)\b(error|failed|fatal|exception)\b"#, options: .regularExpression) != nil ? Theme.red : l.range(of: #"(?i)\bwarn"#, options: .regularExpression) != nil ? Theme.yellow : Theme.textDim)
                            .frame(maxWidth: .infinity, alignment: .leading).id(i)
                    }
                }
                .padding(8).textSelection(.enabled)
            }
            .onChange(of: text) { _, _ in p.scrollTo(lines.count - 1, anchor: .bottom) }
            .onAppear { p.scrollTo(lines.count - 1, anchor: .bottom) }
        }
        .background(Theme.bg)
    }
    var lines: [String] { text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n").suffix(4000).map { $0.replacingOccurrences(of: #"\u{1b}\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression) } }
}

struct CIRuns: View {
    let repo: String
    @Environment(AppModel.self) private var app
    @State private var runs: [WorkflowRun] = []
    @State private var selected: Int?
    @State private var detail: WorkflowRun?
    @State private var log: String?
    @State private var confirm: String?
    @State private var note: String?
    @State private var workflows: [Workflow] = []
    @State private var dispatching: Workflow?

    @Environment(\.compactLayout) private var compact

    var path: String { "/api/github/\(repo)" }

    var body: some View {
        AdaptiveSplit(masterWidth: 340, showingDetail: selected != nil, backTitle: "Runs", onBack: { selected = nil; detail = nil; log = nil }) {
            List(runs, selection: $selected) { r in
                HStack(alignment: .top, spacing: 8) {
                    StatusDot(status: r.state).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.displayTitle).font(.system(size: 13.5)).lineLimit(2)
                        Text("\(r.workflowName) · \(r.headBranch ?? "") · \(String(r.createdAt.prefix(16)).replacingOccurrences(of: "T", with: " "))").font(.system(size: 12)).foregroundStyle(Theme.textFaint).lineLimit(1)
                    }
                }
                .tag(r.databaseId).listRowBackground(selected == r.databaseId ? Theme.hover : Theme.surface)
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .refreshable { await load() }
            .safeAreaInset(edge: .top) {
                Menu {
                    ForEach(workflows.filter { $0.state == "active" }) { w in Button { dispatching = w } label: { Label(w.name, systemImage: "play") } }
                } label: { Label("Run workflow", systemImage: "play.circle").font(Theme.label).frame(maxWidth: .infinity).frame(height: 32) }
                .disabled(workflows.isEmpty).background(Theme.raised)
            }
        } detail: {
            VStack(spacing: 0) {
                if let d = detail {
                    HStack(spacing: 8) {
                        StatusDot(status: d.state); Text(d.workflowName).font(Theme.label); Pill(text: d.state, color: Theme.status(d.state))
                        Spacer()
                        if d.status != "completed" { Button("Cancel") { confirm = "cancel" }.foregroundStyle(Theme.red) }
                        else if d.conclusion != "success" { Button("Re-run failed jobs") { confirm = "rerun" } }
                        Link("GitHub", destination: URL(string: d.url)!)
                    }
                    .font(Theme.label).padding(.horizontal, 10).frame(height: 36).background(Theme.raised)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(d.jobs ?? []) { j in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack { StatusDot(status: j.status == "completed" ? (j.conclusion ?? "") : j.status); Text(j.name).font(.system(size: 14, weight: .medium)) }
                                    ForEach(j.steps ?? [], id: \.name) { s in
                                        HStack(spacing: 6) { StatusDot(status: s.status == "completed" ? (s.conclusion ?? "") : s.status, size: 5); Text(s.name).font(.system(size: 12.5)).foregroundStyle(s.conclusion == "failure" ? Theme.red : Theme.textDim) }.padding(.leading, 14)
                                    }
                                }
                            }
                            if let note { Text(note).font(Theme.caption).foregroundStyle(Theme.textDim) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }
                    .frame(maxHeight: 260)
                    Divider().overlay(Theme.line)
                    if let log { LogView(text: log) } else if d.conclusion == "failure" { ProgressView("Fetching failed step logs…").frame(maxHeight: .infinity) } else { EmptyNote(icon: "doc.plaintext", text: d.status == "completed" ? "Succeeded" : "Running…") }
                } else { EmptyNote(icon: "arrow.triangle.2.circlepath", text: "Choose a workflow run") }
            }
        }
        .task(id: repo) { await load() }
        .task(id: selected) { await loadDetail() }
        .confirmationDialog(confirm == "rerun" ? "Re-run the failed jobs?" : "Cancel this run?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
            Button(confirm == "rerun" ? "Re-run" : "Cancel run", role: confirm == "cancel" ? .destructive : nil) {
                let what = confirm ?? ""
                Task {
                    do { _ = try await app.client.send("POST", "\(path)/runs/\(selected ?? 0)/\(what)", ["confirm": true], as: OK.self); note = what == "rerun" ? "Re-run requested." : "Cancellation requested." }
                    catch { note = error.localizedDescription }
                    await load(); await loadDetail()
                }
            }
        } message: { Text("This acts on \(repo) on GitHub.") }
        .confirmationDialog("Run \(dispatching?.name ?? "") on \(repo)?", isPresented: Binding(get: { dispatching != nil }, set: { if !$0 { dispatching = nil } }), titleVisibility: .visible) {
            Button("Run with default inputs") {
                guard let w = dispatching else { return }
                Task {
                    do { _ = try await app.client.send("POST", "\(path)/dispatch", ["confirm": true, "workflow": (w.path as NSString).lastPathComponent], as: OK.self); note = "Started \(w.name)." }
                    catch { note = error.localizedDescription }
                    try? await Task.sleep(nanoseconds: 3_000_000_000); await load()
                }
            }
        } message: { Text("Workflows can build, sign or publish. It runs on the default branch with its default inputs.") }
    }

    func load() async {
        if workflows.isEmpty { workflows = (try? await app.client.get("\(path)/workflows", as: [Workflow].self)) ?? [] }
        runs = (try? await app.client.get("\(path)/runs", ["limit": "30"], as: [WorkflowRun].self)) ?? []
        if selected == nil && !compact { selected = runs.first?.databaseId }
    }
    func loadDetail() async {
        guard let s = selected else { return }
        log = nil
        detail = try? await app.client.get("\(path)/runs/\(s)", as: WorkflowRun.self)
        if detail?.conclusion == "failure" { log = (try? await app.client.get("\(path)/runs/\(s)/log", as: LogText.self, timeout: 90).text) ?? "Couldn't fetch logs." }
    }
}

struct PullRequests: View {
    let repo: String
    @Environment(AppModel.self) private var app
    @State private var prs: [PullRequest] = []
    @State private var selected: Int?
    @State private var diff = ""
    var body: some View {
        AdaptiveSplit(masterWidth: 340, showingDetail: selected != nil, backTitle: "Pull requests", onBack: { selected = nil; diff = "" }) {
            List(prs, selection: $selected) { p in
                VStack(alignment: .leading, spacing: 2) {
                    HStack { Text("#\(p.number)").font(Theme.monoSmall).foregroundStyle(Theme.accent); Pill(text: p.isDraft == true ? "draft" : p.state.lowercased(), color: p.state == "OPEN" ? Theme.green : p.state == "MERGED" ? Theme.purple : Theme.textDim) }
                    Text(p.title).font(.system(size: 13.5)).lineLimit(2)
                    Text("\(p.headRefName ?? "") → \(p.baseRefName ?? "") · +\(p.additions ?? 0) −\(p.deletions ?? 0)").font(.system(size: 12)).foregroundStyle(Theme.textFaint)
                }
                .tag(p.number).listRowBackground(selected == p.number ? Theme.hover : Theme.surface)
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .overlay { if prs.isEmpty { EmptyNote(icon: "arrow.triangle.pull", text: "No pull requests") } }
        } detail: {
            DiffView(diff: diff, emptyText: "Choose a pull request")
        }
        .task(id: repo) { prs = (try? await app.client.get("/api/github/\(repo)/pulls", as: [PullRequest].self)) ?? [] }
        .task(id: selected) { if let s = selected { diff = (try? await app.client.get("/api/github/\(repo)/pulls/\(s)/diff", as: DiffResponse.self).diff) ?? "" } }
    }
}
