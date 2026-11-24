import SwiftUI

extension Agent {
    var tint: Color { agent == "gemini" ? Theme.purple : agent == "claude" ? Theme.accent : Theme.blue }
    var shortName: String { agent == "gemini" ? "Gemini" : agent == "claude" ? "Claude" : "Codex" }
}

/// Watch an agent work. Everything here is something that actually happened:
/// the file it opened (read from disk), the edit it made (its own diff, or
/// the watcher's revision diff), its terminal (the live tmux screen), test
/// output, images it captured and pages it published. Nothing is animated
/// or replayed. Following switches the view as new events arrive; touching
/// anything pauses following so you can look around, and the agent carries
/// on regardless.
struct AgentLivePanel: View {
    let projectId: String?
    let agentConfig: String?                 // pinned agent id, nil = the latest active agent here
    let setAgent: (String?) -> Void
    @Environment(AppModel.self) private var app
    @Environment(DesktopStore.self) private var desk
    @State private var following = true
    @State private var tab: Stage = .live
    @State private var inspected: TimelineEvent?
    @State private var history: [TimelineEvent] = []
    @State private var actionError: String?
    @State private var confirmEnd = false

    enum Stage: String, CaseIterable, Identifiable {
        case live, editor, terminal, steps
        var id: String { rawValue }
        var title: String { switch self { case .live: return "Live"; case .editor: return "Files"; case .terminal: return "Terminal"; case .steps: return "Steps" } }
    }

    var candidates: [Agent] {
        app.agents.filter { a in
            (projectId == nil || a.project == projectId) && (a.isLive || Date().timeIntervalSince1970 * 1000 - a.lastActivity < 6 * 3600_000)
        }
    }
    var agent: Agent? {
        if let id = agentConfig, let a = app.agent(id) { return a }
        return candidates.first { $0.status == "approval" } ?? candidates.first { $0.status == "working" } ?? candidates.first { $0.isLive } ?? candidates.first
    }

    /// Real events for this agent, newest last: what arrived live plus the
    /// recorded timeline loaded when the panel opened.
    var events: [TimelineEvent] {
        guard let a = agent else { return [] }
        var seen = Set<String>()
        return (history + app.liveEvents.filter { $0.session == a.id })
            .filter { seen.insert($0.stableId).inserted }
            .sorted { $0.ts < $1.ts }
    }

    /// The newest event with something to look at.
    var liveEvent: TimelineEvent? {
        events.last { e in
            ["agent.edit", "agent.read", "file.changed", "agent.command", "agent.command_done", "agent.command_failed", "agent.test",
             "agent.image", "screenshot.new", "agent.approval", "agent.plan", "agent.message", "agent.tool", "agent.done", "agent.error", "visual.output"].contains(e.kind)
        }
    }
    var shown: TimelineEvent? { following ? liveEvent : (inspected ?? liveEvent) }

    var body: some View {
        VStack(spacing: 0) {
            if let a = agent {
                header(a)
                if let p = a.approval {
                    ApprovalCard(agent: a, prompt: p).padding(8).background(Theme.bg)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                stageBar
                stage(a).frame(maxWidth: .infinity, maxHeight: .infinity)
                if let actionError { Label(actionError, systemImage: "exclamationmark.triangle").font(Theme.caption).foregroundStyle(Theme.red).padding(6).frame(maxWidth: .infinity, alignment: .leading) }
                AgentComposer(agent: a)
            } else {
                empty
            }
        }
        .background(Theme.surface)
        .task(id: agent?.id) { await loadHistory() }
        .onChange(of: liveEvent?.stableId) { _, _ in
            guard following, let e = liveEvent else { return }
            // Follow the work: switch the stage to where it's happening.
            if tab != .live && tab != .steps { tab = .live }
            if e.follow?["view"]?.string == "vnc", desk.followAgents, !app.followPaused { app.showDesktop(follow: true) }
        }
        .confirmationDialog("End this \(agent?.agentName ?? "agent") session?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End session", role: .destructive) { act { a in _ = try await app.client.send("POST", "/api/agents/\(a.id.pathSegment)/end", ["confirm": true], as: OK.self) } }
        } message: { Text("Stops the agent and closes its tmux session. Its transcript stays on the server.") }
    }

    var empty: some View {
        VStack(spacing: 12) {
            EmptyNote(icon: "sparkles", text: "No agent working here yet", detail: "Start Claude, Codex or Gemini in this project. You'll see the files it opens, every edit, its terminal and anything it renders, as it happens.")
            Button { app.launcherProject = projectId; app.showLauncher = true } label: { Label("New agent task", systemImage: "plus") }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: header

    func header(_ a: Agent) -> some View {
        HStack(spacing: 6) {
            Menu {
                Button { setAgent(nil) } label: { Label("Follow the most active agent", systemImage: agentConfig == nil ? "checkmark" : "scope") }
                Divider()
                ForEach(candidates) { c in
                    Button { setAgent(c.id) } label: { Label("\(c.shortName): \(c.title)", systemImage: agentConfig == c.id ? "checkmark" : c.icon) }
                }
            } label: {
                HStack(spacing: 6) {
                    StatusDot(status: a.status, size: 7)
                    Text(a.shortName).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(a.tint)
                    Text(a.title).font(.system(size: 12.5)).foregroundStyle(Theme.text).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).foregroundStyle(Theme.textFaint)
                }
            }
            .accessibilityIdentifier("agent.picker")
            Spacer(minLength: 6)
            followButton
            if a.controllable { controls(a) }
            more(a)
        }
        .padding(.horizontal, 8).frame(height: 34)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    var followButton: some View {
        Button {
            following.toggle()
            if following { inspected = nil; tab = .live }
        } label: {
            Label(following ? "Following" : "Paused", systemImage: following ? "dot.radiowaves.left.and.right" : "pause.circle")
                .font(.system(size: 11.5, weight: .semibold))
                .padding(.horizontal, 8).frame(height: 22)
                .background(following ? Theme.green.opacity(0.16) : Theme.hover, in: Capsule())
                .foregroundStyle(following ? Theme.green : Theme.textDim)
        }
        .buttonStyle(.plain)
        .help(following ? "Following the agent's activity. Tap to stop switching views (the agent keeps working)." : "Inspecting. Tap to follow live again.")
        .accessibilityIdentifier("agent.follow")
    }

    @ViewBuilder func controls(_ a: Agent) -> some View {
        if a.status == "paused" {
            IconButton(systemName: "play.fill", help: "Resume the agent", tint: Theme.green) { act { a in _ = try await app.client.send("POST", "/api/agents/\(a.id.pathSegment)/resume", [:], as: OK.self) } }
        } else if a.isLive {
            IconButton(systemName: "pause.fill", help: "Pause the agent (freezes it; resume continues)") { act { a in _ = try await app.client.send("POST", "/api/agents/\(a.id.pathSegment)/pause", [:], as: OK.self) } }
        }
        if a.isLive {
            IconButton(systemName: "stop.circle", help: "Interrupt the current step (Esc)", tint: Theme.yellow) { act { a in _ = try await app.client.send("POST", "/api/agents/\(a.id.pathSegment)/interrupt", [:], as: OK.self) } }
        }
    }

    func more(_ a: Agent) -> some View {
        Menu {
            if let t = a.tmux?.session { Button { app.showTerminal(tmux: t, title: a.shortName) } label: { Label("Open its terminal", systemImage: "terminal") } }
            Button { app.workspace.reveal(.visualiser) } label: { Label("Show Visualiser", systemImage: "chart.xyaxis.line") }
            if !a.isLive, let sid = a.sessionId, let p = a.project {
                Button { act { a in _ = try await app.client.send("POST", "/api/agents", ["agent": a.agent, "project": p, "resume": sid], as: LaunchResult.self) } } label: { Label("Resume session", systemImage: "arrow.clockwise") }
            }
            if let c = a.counts { Section("This session") { Text("\(c.edits) edits · \(c.commands) commands · \(c.images) images") } }
            Button { UIPasteboard.general.string = a.sessionId } label: { Label("Copy session id", systemImage: "doc.on.doc") }
            if a.managed != nil { Divider(); Button(role: .destructive) { confirmEnd = true } label: { Label("End session…", systemImage: "xmark.circle") } }
        } label: { Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textDim).frame(width: 30, height: 30) }
        .accessibilityLabel("More agent actions")
    }

    var stageBar: some View {
        HStack(spacing: 2) {
            ForEach(Stage.allCases) { s in
                let on = tab == s
                Button {
                    tab = s
                    if s != .live { following = false } else { following = true; inspected = nil }
                } label: {
                    Text(s.title).font(.system(size: 12, weight: on ? .semibold : .regular))
                        .padding(.horizontal, 9).frame(height: 24)
                        .background(on ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(on ? Theme.text : Theme.textDim)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("agent.stage.\(s.rawValue)")
            }
            Spacer()
            if let e = shown { nowLine(e) }
        }
        .padding(.horizontal, 6).frame(height: 30)
        .background(Theme.bg)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    func nowLine(_ e: TimelineEvent) -> some View {
        HStack(spacing: 5) {
            Image(systemName: e.icon).font(.system(size: 10.5))
            Text(e.title).lineLimit(1).truncationMode(.middle)
            Text(Fmt.ago(e.ts)).foregroundStyle(Theme.textFaint)
        }
        .font(.system(size: 11.5)).foregroundStyle(Theme.textDim)
        .frame(maxWidth: 360, alignment: .trailing)
    }

    // MARK: stage

    @ViewBuilder func stage(_ a: Agent) -> some View {
        switch tab {
        case .terminal: AgentScreen(agent: a)
        case .editor: AgentFiles(events: events, open: { e in inspected = e; following = false; tab = .live })
        case .steps: steps
        case .live:
            if let e = shown { LiveEvidence(event: e, agent: a).id(e.stableId) }
            else if a.isLive { AgentScreen(agent: a) }
            else { EmptyNote(icon: "clock", text: "Nothing recorded yet", detail: "This session's activity will appear here.") }
        }
    }

    var steps: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(events.suffix(300), id: \.stableId) { e in
                    Button { inspected = e; following = false; tab = .live } label: {
                        HStack(spacing: 8) {
                            Image(systemName: e.icon).font(.system(size: 11)).foregroundStyle(e.tint == "other" ? Theme.textFaint : Theme.status(e.tint)).frame(width: 16)
                            Text(e.title).font(.system(size: 12.5)).foregroundStyle(Theme.text).lineLimit(1)
                            Spacer()
                            Text(Fmt.time(e.ts)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textFaint)
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(inspected?.stableId == e.stableId ? Theme.hover : Theme.surface)
                    .listRowInsets(EdgeInsets(top: 3, leading: 10, bottom: 3, trailing: 10))
                    .id(e.stableId)
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .onAppear { if let l = events.last { proxy.scrollTo(l.stableId, anchor: .bottom) } }
        }
    }

    func loadHistory() async {
        guard let a = agent else { history = []; return }
        history = (try? await app.client.get("/api/agents/\(a.id.pathSegment)/timeline", ["limit": "200"], as: [TimelineEvent].self)) ?? []
    }

    func act(_ f: @escaping (Agent) async throws -> Void) {
        guard let a = agent else { return }
        Task { do { actionError = nil; try await f(a); await app.refreshAgents() } catch { actionError = error.localizedDescription } }
    }
}

/// One real event, shown the way it happened.
struct LiveEvidence: View {
    let event: TimelineEvent
    let agent: Agent
    @Environment(AppModel.self) private var app
    @Environment(DesktopStore.self) private var desk
    @State private var file: FileContent?
    @State private var showFile = false
    @State private var loadError: String?

    var path: String? { event.detail?["path"]?.string }

    var body: some View {
        switch event.kind {
        case "agent.read":
            VStack(spacing: 0) {
                fileBar(badge: "Opened", tint: Theme.blue)
                if let t = file?.text, let p = path { CodeView(text: t, path: p) }
                else if let loadError { EmptyNote(icon: "doc", text: "Can't show this file", detail: loadError) }
                else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            .task(id: event.stableId) { await loadFile() }
        case "agent.edit":
            VStack(spacing: 0) {
                fileBar(badge: editBadge, tint: event.detail?["change"]?.string == "delete" ? Theme.red : Theme.green, toggle: true)
                if showFile {
                    if let t = file?.text, let p = path { CodeView(text: t, path: p, changed: changedLines(in: t), scrollTo: changedLines(in: t).min()) }
                    else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).task { await loadFile() } }
                } else {
                    EvidenceView(event: event)
                }
            }
        case "agent.command", "agent.test":
            // Still running: its terminal is the real output.
            VStack(spacing: 0) {
                commandBar(running: true)
                AgentScreen(agent: agent)
            }
        case "agent.command_done", "agent.command_failed":
            VStack(spacing: 0) {
                commandBar(running: false)
                EvidenceView(event: event)
            }
        case "agent.tool" where event.follow?["view"]?.string == "vnc":
            VStack(spacing: 12) {
                EmptyNote(icon: "display", text: "\(agent.shortName) is using the browser", detail: event.title)
                Button { app.showDesktop(follow: false) } label: { Label(desk.active ? "Bring Remote Desktop forward" : "Watch in Remote Desktop", systemImage: "display") }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case "agent.message":
            ScrollView {
                MessageBlock(event: event, prominent: true)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
        case "visual.output":
            VisualItemView(project: event.project ?? agent.project ?? "_shared", item: VisualItem(event: event))
        default:
            EvidenceView(event: event)
        }
    }

    var editBadge: String {
        switch event.detail?["change"]?.string { case "add": return "Created"; case "delete": return "Deleted"; default: return event.detail?["tool"]?.string == "Write" ? "Wrote" : "Edited" }
    }

    @ViewBuilder func fileBar(badge: String, tint: Color, toggle: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(badge).font(.system(size: 10.5, weight: .bold)).foregroundStyle(tint)
                .padding(.horizontal, 6).padding(.vertical, 2).background(tint.opacity(0.14), in: Capsule())
            Text(app.locate(path)?.rel ?? path ?? "").font(Theme.monoSmall).lineLimit(1).truncationMode(.head)
            Spacer()
            if toggle {
                Picker("", selection: $showFile) { Text("Change").tag(false); Text("Whole file").tag(true) }
                    .pickerStyle(.segmented).frame(width: 170)
            }
            if let loc = app.locate(path) {
                Button { app.openFile(project: loc.project.id, path: loc.rel) } label: { Label("Edit", systemImage: "square.and.pencil") }
                    .font(Theme.caption).help("Open in the editor")
            }
        }
        .padding(.horizontal, 10).frame(height: 30).background(Theme.bg)
    }

    func commandBar(running: Bool) -> some View {
        HStack(spacing: 6) {
            if running { ProgressView().controlSize(.mini) }
            else if let ok = event.detail?["ok"]?.bool { Image(systemName: ok ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(ok ? Theme.green : Theme.red) }
            Text("$ " + (event.detail?["command"]?.string ?? event.title)).font(Theme.monoSmall).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.tail)
            Spacer()
        }
        .padding(.horizontal, 10).frame(height: 30).background(Theme.bg)
    }

    func loadFile() async {
        guard let loc = app.locate(path) else { loadError = "It's outside the projects Musa Control can open."; return }
        do { file = try await app.client.get("/api/projects/\(loc.project.id)/file", ["path": loc.rel], as: FileContent.self) }
        catch { loadError = error.localizedDescription }
    }

    /// Lines of the current file that the edit's new text occupies.
    func changedLines(in text: String) -> Set<Int> {
        var out = Set<Int>()
        let lines = text.components(separatedBy: "\n")
        var news: [String] = event.detail?["edits"]?.array.compactMap { $0["new"]?.string } ?? []
        if let d = event.detail?["diff"]?.string {
            news.append(d.components(separatedBy: "\n").filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.map { String($0.dropFirst()) }.joined(separator: "\n"))
        }
        for n in news {
            let nl = n.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard let first = nl.first else { continue }
            for (i, l) in lines.enumerated() where l == first {
                let span = nl.count
                if i + span <= lines.count { for j in i..<(i + span) { out.insert(j + 1) } }
                break
            }
        }
        return out
    }
}

/// Files the agent opened or changed in this session, most recent first.
struct AgentFiles: View {
    let events: [TimelineEvent]
    let open: (TimelineEvent) -> Void
    @Environment(AppModel.self) private var app

    var files: [(path: String, last: TimelineEvent, edits: Int)] {
        var order: [String] = [], last: [String: TimelineEvent] = [:], edits: [String: Int] = [:]
        for e in events where ["agent.read", "agent.edit", "file.changed"].contains(e.kind) {
            guard let p = e.detail?["path"]?.string else { continue }
            if last[p] == nil { order.append(p) }
            last[p] = e
            if e.kind != "agent.read" { edits[p, default: 0] += 1 }
        }
        return order.compactMap { p in last[p].map { (p, $0, edits[p] ?? 0) } }.sorted { $0.last.ts > $1.last.ts }
    }

    var body: some View {
        if files.isEmpty {
            EmptyNote(icon: "doc.on.doc", text: "No files touched yet", detail: "Files the agent reads or edits appear here.")
        } else {
            List(files, id: \.path) { f in
                Button { open(f.last) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: f.edits > 0 ? "pencil.line" : "doc.text").font(.system(size: 12)).foregroundStyle(f.edits > 0 ? Theme.green : Theme.textDim).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text((f.path as NSString).lastPathComponent).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                            Text(app.locate(f.path)?.rel ?? f.path).font(.system(size: 11)).foregroundStyle(Theme.textFaint).lineLimit(1).truncationMode(.head)
                        }
                        Spacer()
                        if f.edits > 0 { Text("\(f.edits) edit\(f.edits == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(Theme.green) }
                        Text(Fmt.ago(f.last.ts)).font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                    }
                }
                .buttonStyle(.plain).listRowBackground(Theme.surface)
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
        }
    }
}
