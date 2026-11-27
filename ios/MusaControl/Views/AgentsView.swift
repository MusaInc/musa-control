import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import SwiftTerm

/// The centre of Musa Control: every Claude Code, Codex and Gemini session,
/// with a unified real-time conversation showing everything the agent does.
struct AgentsView: View {
    @Environment(AppModel.self) private var app
    @State private var filter = "live"

    var list: [Agent] {
        switch filter {
        case "live": return app.agents.filter { $0.status != "ended" }
        case "attention": return app.agents.filter { $0.status == "approval" || $0.status == "failed" }
        default: return app.agents
        }
    }

    var body: some View {
        GeometryReader { geo in
            let narrow = geo.size.width < 760
            let listWidth = min(max(geo.size.width * 0.28, 270), 340)
            HStack(spacing: 0) {
                if !narrow || app.focusedAgent == nil {
                    listColumn.frame(width: narrow ? geo.size.width : listWidth)
                    if !narrow { Rectangle().fill(Theme.line).frame(width: 1) }
                }
                if !narrow || app.focusedAgent != nil {
                    Group {
                        if let id = app.focusedAgent, let a = app.agent(id) {
                            AgentDetail(agent: a, onBack: narrow ? { app.focusedAgent = nil } : nil).id(a.id)
                        } else if app.focusedAgent != nil {
                            VStack(spacing: 0) {
                                if narrow { BackBar(title: "Agents") { app.focusedAgent = nil } }
                                EmptyNote(icon: "sparkles", text: "Loading session…", detail: "If it doesn't appear, the session may have ended.")
                            }
                        } else {
                            VStack(spacing: 14) {
                                EmptyNote(
                                    icon: "sparkles",
                                    text: "Choose an agent",
                                    detail: "Every Claude Code, Codex and Gemini session on this machine appears here — live messages, diffs, images, commands and desktop previews in one conversation."
                                )
                                Button { app.launcherProject = nil; app.showLauncher = true } label: {
                                    Label("New agent task", systemImage: "plus")
                                }
                                .buttonStyle(.borderedProminent).tint(Theme.accent)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(Theme.bg)
        .task {
            await app.refreshAgents()
            if app.focusedAgent == nil && !Device.isPhone {
                app.focusedAgent = app.agents.first(where: { $0.status == "approval" })?.id
                    ?? app.agents.first(where: { $0.isLive })?.id
                    ?? app.agents.first?.id
            }
        }
    }

    var listColumn: some View {
        @Bindable var app = app
        return VStack(spacing: 0) {
            PanelHeader(icon: "sparkles", title: "Agents", subtitle: "\(app.agents.filter { $0.isLive }.count) running") {
                IconButton(systemName: "plus", help: "New agent task (⇧⌘N)", tint: Theme.accent) {
                    app.launcherProject = app.agent(app.focusedAgent)?.project
                    app.showLauncher = true
                }
                .accessibilityIdentifier("agents.new")
            }
            Picker("Show", selection: $filter) {
                Text("Running").tag("live")
                Text("Needs you").tag("attention")
                Text("All").tag("all")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12).padding(.vertical, 8)

            List(list, selection: $app.focusedAgent) { a in
                AgentRow(agent: a).tag(a.id)
                    .listRowBackground(app.focusedAgent == a.id ? Theme.hover : Theme.surface)
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    .listRowSeparatorTint(Theme.line)
                    .accessibilityIdentifier("agentrow.\(a.id)")
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .overlay {
                if list.isEmpty {
                    EmptyNote(
                        icon: "sparkles",
                        text: filter == "attention" ? "Nothing needs you" : "No agents",
                        detail: "Start one with + above (⇧⌘N)."
                    )
                }
            }
            .refreshable { await app.refreshAgents() }
        }
        .background(Theme.surface)
    }
}

struct BackBar: View {
    let title: String
    let action: () -> Void
    var body: some View {
        HStack {
            Button(action: action) {
                Label(title, systemImage: "chevron.left").font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.accent).keyboardShortcut("[", modifiers: .command)
            .accessibilityIdentifier("back")
            Spacer()
        }
        .padding(.horizontal, 12).frame(height: 40).background(Theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

/// One agent's unified real-time conversation + contextual actions + composer.
struct AgentDetail: View {
    let agent: Agent
    var onBack: (() -> Void)? = nil
    @Environment(AppModel.self) private var app
    @State private var confirmEnd = false
    @State private var showScreenSheet = false
    @State private var error: String?
    @State private var titleExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            if let onBack { BackBar(title: "Agents", action: onBack) }
            header
            if let p = agent.approval {
                ApprovalCard(agent: agent, prompt: p)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .frame(maxWidth: 880).frame(maxWidth: .infinity)
                    .background(Theme.bg)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            AgentTimeline(agent: agent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(Theme.caption).foregroundStyle(Theme.red)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            AgentComposer(agent: agent)
        }
        .background(Theme.bg)
        .sheet(isPresented: $showScreenSheet) {
            VStack(spacing: 0) {
                HStack {
                    Text("\(agent.agentName) · Live Screen").font(Theme.title)
                    Spacer()
                    if let t = agent.tmux?.session {
                        Button("Open in Terminal") { showScreenSheet = false; app.attachTerminal(t) }
                            .font(Theme.label).foregroundStyle(Theme.accent)
                    }
                    Button("Done") { showScreenSheet = false }.font(Theme.label).padding(.leading, 8)
                }
                .padding(.horizontal, 16).frame(height: 48).background(Theme.surface)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
                AgentScreen(agent: agent)
            }
            .frame(minWidth: Device.isPhone ? nil : 720, minHeight: Device.isPhone ? nil : 540)
        }
        .confirmationDialog("End this \(agent.agentName) session?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End session", role: .destructive) {
                act { _ = try await app.client.send("POST", "/api/agents/\(agent.id.pathSegment)/end", ["confirm": true], as: OK.self) }
            }
        } message: { Text("Stops the agent and closes its tmux session. Its transcript and history stay on the server.") }
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: agent.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(agent.tint)
                    .frame(width: 38, height: 38)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if let p = app.project(agent.project) {
                            Button { app.openWorkspace(p.id) } label: {
                                Text(p.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.accent)
                            }
                            .buttonStyle(.plain)
                            Text("·").foregroundStyle(Theme.textFaint)
                        }
                        Text(agent.agentName).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textDim)
                        if let m = agent.model {
                            Text("·").foregroundStyle(Theme.textFaint)
                            Text(m).font(.system(size: 12)).foregroundStyle(Theme.textFaint).lineLimit(1)
                        }
                    }
                    Text(agent.title)
                        .font(.system(size: 16.5, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(titleExpanded ? 6 : 2)
                        .fixedSize(horizontal: false, vertical: true)
                        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { titleExpanded.toggle() } }
                }
                .layoutPriority(1)

                Spacer(minLength: 8)

                HStack(spacing: 2) {
                    if agent.controllable && agent.isLive {
                        if agent.status == "paused" {
                            IconButton(systemName: "play.fill", help: "Resume agent", tint: Theme.green) {
                                act { _ = try await app.client.send("POST", "/api/agents/\(agent.id.pathSegment)/resume", [:], as: OK.self) }
                            }
                        } else {
                            IconButton(systemName: "pause.fill", help: "Pause agent") {
                                act { _ = try await app.client.send("POST", "/api/agents/\(agent.id.pathSegment)/pause", [:], as: OK.self) }
                            }
                        }
                        IconButton(systemName: "stop.circle", help: "Interrupt (⌘.)", tint: Theme.yellow) {
                            act { _ = try await app.client.send("POST", "/api/agents/\(agent.id.pathSegment)/interrupt", [:], as: OK.self) }
                        }
                    } else if !agent.isLive, let sid = agent.sessionId, let p = agent.project {
                        Button {
                            act {
                                let r = try await app.client.send("POST", "/api/agents", ["agent": agent.agent, "project": p, "resume": sid], as: LaunchResult.self)
                                if let k = r.sessionKey { app.focusedAgent = k }
                            }
                        } label: {
                            Label("Resume", systemImage: "arrow.clockwise")
                                .font(.system(size: 12.5, weight: .semibold))
                                .padding(.horizontal, 10).frame(height: 28)
                                .background(Theme.accent.opacity(0.14), in: Capsule())
                                .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                    if let p = agent.project {
                        IconButton(systemName: "arrow.triangle.branch", help: "Git & Builds") {
                            app.openGitBuilds(project: p)
                        }
                    }
                    IconButton(systemName: "display", help: "Remote Desktop (⌃⌘D)") {
                        app.showDesktop(follow: false)
                    }
                    moreMenu
                }
            }

            HStack(spacing: 8) {
                StatusDot(status: agent.status, size: 7)
                Text(nowText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(agent.status == "approval" ? Theme.yellow : Theme.textDim)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                if let c = agent.counts, c.edits + c.commands + c.images > 0 {
                    Text("\(c.edits) edits · \(c.commands) cmds\(c.images > 0 ? " · \(c.images) imgs" : "")")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    var nowText: String {
        switch agent.status {
        case "approval": return "Waiting for your approval"
        case "working": return agent.lastEvent.map { stepTitleText($0.title) } ?? "Working"
        case "paused": return "Paused — resume to continue"
        case "idle": return "Idle — ready for instructions"
        case "exited": return "Exited (tmux kept)"
        case "failed": return agent.statusText
        default: return "Ended · last active \(Fmt.ago(agent.lastActivity)) ago"
        }
    }
    func stepTitleText(_ t: String) -> String { t.hasPrefix("$ ") ? "Running " + String(t.dropFirst(2)) : t }

    var moreMenu: some View {
        Menu {
            if let t = agent.tmux?.session {
                Button { app.attachTerminal(t) } label: { Label("Open in Terminal", systemImage: "terminal") }
            }
            if agent.controllable || agent.agent == "gemini" {
                Button { showScreenSheet = true } label: { Label("View live terminal screen", systemImage: "rectangle.and.text.magnifyingglass") }
            }
            if let p = agent.project {
                Button { app.openWorkspace(p) } label: { Label("Browse project files", systemImage: "folder") }
                Button { app.openGitBuilds(project: p) } label: { Label("Git & Builds", systemImage: "arrow.triangle.branch") }
            }
            Button { app.showDesktop(follow: false) } label: { Label("Remote Desktop", systemImage: "display") }
            if let sid = agent.sessionId {
                Button { UIPasteboard.general.string = sid } label: { Label("Copy session ID", systemImage: "doc.on.doc") }
            }
            if agent.managed != nil {
                Divider()
                Button(role: .destructive) { confirmEnd = true } label: { Label("End session…", systemImage: "xmark.circle") }
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 16)).foregroundStyle(Theme.textDim).frame(width: 34, height: 34)
        }
        .accessibilityLabel(Text("More actions"))
    }

    func act(_ f: @escaping () async throws -> Void) {
        Task { do { error = nil; try await f(); await app.refreshAgents() } catch { self.error = error.localizedDescription } }
    }
}

/// The unified chronological conversation feed. Automatically reloads history
/// on reconnect or foreground return so no events are ever missed.
struct AgentTimeline: View {
    let agent: Agent
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var events: [TimelineEvent] = []
    @State private var inspection: InspectionItem?
    @State private var following = true
    @State private var loaded = false

    var merged: [TimelineEvent] {
        var seen = Set<String>()
        let live = app.liveEvents.filter { ev in
            if ev.session == agent.id { return true }
            if ev.session == nil, let p = agent.project, ev.project == p,
               ev.kind == "visual.output" || Feed.isBuild(ev) {
                return agent.isLive
            }
            return false
        }
        return (events + live)
            .filter { seen.insert($0.stableId).inserted }
            .sorted { $0.ts < $1.ts }
            .suffix(600)
            .map { $0 }
    }

    var body: some View {
        let items = merged
        let feed = Feed.build(items)
        let latestMessage = items.last(where: { $0.kind == "agent.message" })?.stableId
        let latestDesktop = items.last(where: { Feed.isDesktop($0) })?.stableId
        let runningCommandId: String? = {
            guard agent.isLive && agent.status == "working" else { return nil }
            guard let last = items.last else { return nil }
            if (last.kind == "agent.command" || last.kind == "agent.test"),
               last.detail?["exitCode"]?.number == nil && (last.detail?["output"]?.string ?? "").isEmpty {
                return last.stableId
            }
            return nil
        }()

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(feed) { entry in
                        FeedEntryView(
                            entry: entry,
                            agent: agent,
                            latestMessageId: latestMessage,
                            latestDesktopId: latestDesktop,
                            runningCommandId: runningCommandId,
                            inspect: { inspection = $0 }
                        )
                        .id(entry.id)
                    }
                    if agent.status == "working" {
                        LiveProgressRow(agent: agent).id("working-indicator")
                    }
                    Color.clear.frame(height: 12).id("bottom")
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
                .frame(maxWidth: 880, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { v in
                if v.translation.height > 12 { following = false }
            })
            .onChange(of: items.count) { _, _ in
                if following { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            .onChange(of: loaded) { _, l in
                if l { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !following {
                    Button {
                        following = true
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    } label: {
                        Label("Latest", systemImage: "arrow.down")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 13).frame(height: 34)
                            .background(.regularMaterial, in: Capsule())
                            .overlay(Capsule().stroke(Theme.lineStrong))
                    }
                    .buttonStyle(.plain).padding(16).transition(.opacity)
                }
            }
        }
        .overlay {
            if items.isEmpty {
                if loaded {
                    EmptyNote(icon: "text.bubble", text: "No activity yet", detail: "Messages, code changes, images, commands and visualisations appear here in real time.")
                } else {
                    ProgressView()
                }
            }
        }
        .fullScreenCover(item: $inspection) { item in
            FullScreenInspector(item: item)
        }
        .task(id: agent.id) { await reload() }
        .onChange(of: app.reconnectTick) { _, _ in Task { await reload() } }
        .onChange(of: scenePhase) { _, p in if p == .active { Task { await reload() } } }
    }

    func reload() async {
        if let e = try? await app.client.get("/api/agents/\(agent.id.pathSegment)/timeline", ["limit": "500"], as: [TimelineEvent].self) {
            events = e
        }
        loaded = true
    }
}

/// Mirror of the agent's tmux screen (ANSI capture), refreshed while visible.
struct AgentScreen: View {
    let agent: Agent
    @Environment(AppModel.self) private var app
    @State private var text: String?
    @State private var controllable = true

    var body: some View {
        Group {
            if !controllable && agent.agent == "gemini", let text, !text.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Recorded command activity · read-only", systemImage: "eye")
                        .font(Theme.caption).foregroundStyle(Theme.textDim)
                    ScreenMirror(text: text)
                }
            } else if !controllable {
                EmptyNote(icon: "eye.slash", text: "Not running in tmux", detail: "This session was started outside tmux, so its screen can't be mirrored. Its conversation history is still recorded.")
            } else if let text {
                ScreenMirror(text: text)
            } else {
                ProgressView()
            }
        }
        .task(id: agent.id) {
            while !Task.isCancelled {
                if let s = try? await app.client.get("/api/agents/\(agent.id.pathSegment)/screen", ["lines": "300"], as: ScreenCapture.self) {
                    controllable = s.controllable; text = s.text
                }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
        }
    }
}

struct ScreenMirror: UIViewRepresentable {
    let text: String
    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let v = SwiftTerm.TerminalView(frame: .zero)
        v.font = UIFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        v.nativeBackgroundColor = Theme.terminalBg
        v.nativeForegroundColor = Theme.terminalFg
        v.backgroundColor = v.nativeBackgroundColor
        return v
    }
    func updateUIView(_ v: SwiftTerm.TerminalView, context: Context) {
        guard context.coordinator.last != text else { return }
        context.coordinator.last = text
        v.feed(text: "\u{1b}[H\u{1b}[2J\u{1b}[3J" + text.replacingOccurrences(of: "\n", with: "\r\n"))
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var last = "" }
}

/// Send instructions (and images/files) to a tmux-hosted agent.
struct AgentComposer: View {
    let agent: Agent
    @Environment(AppModel.self) private var app
    @State private var text = ""
    @State private var sending = false
    @State private var attachments: [(name: String, path: String)] = []
    @State private var photo: PhotosPickerItem?
    @State private var importing = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachments, id: \.path) { a in
                            Pill(text: "📎 " + a.name, color: Theme.accent)
                        }
                    }
                }
            }
            if let error { Text(error).font(Theme.caption).foregroundStyle(Theme.red) }
            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(selection: $photo, matching: .images) {
                    Image(systemName: "photo").font(.system(size: 15)).foregroundStyle(Theme.textDim).frame(width: 32, height: 36)
                }
                .disabled(!agent.controllable)

                Button { importing = true } label: {
                    Image(systemName: "paperclip").font(.system(size: 15)).foregroundStyle(Theme.textDim).frame(width: 32, height: 36)
                }
                .buttonStyle(.plain).disabled(!agent.controllable)

                TextField(
                    agent.controllable
                        ? (agent.status == "approval" ? "Answer the approval request above first" : (Device.isPhone ? "Message \(agent.agentName)…" : "Message \(agent.agentName)…  (⌘↩ to send)"))
                        : "Read-only — session isn't running in tmux",
                    text: $text,
                    axis: .vertical
                )
                .lineLimit(1...8).font(.system(size: 15)).focused($focused)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
                .disabled(!agent.controllable)
                .accessibilityIdentifier("agent.composer")

                Button(action: send) {
                    Image(systemName: sending ? "hourglass" : "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 36, height: 36)
                        .background(canSend ? Theme.accent : Theme.textFaint, in: Circle())
                }
                .buttonStyle(.plain).disabled(!canSend).keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel(Text("Send message"))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.surface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await upload(data: data, name: "image-\(Int(Date().timeIntervalSince1970)).png")
                }
                photo = nil
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
            guard case .success(let urls) = r else { return }
            Task {
                for u in urls {
                    let ok = u.startAccessingSecurityScopedResource()
                    defer { if ok { u.stopAccessingSecurityScopedResource() } }
                    if let d = try? Data(contentsOf: u) { await upload(data: d, name: u.lastPathComponent) }
                }
            }
        }
    }

    var canSend: Bool {
        agent.controllable && !sending && agent.status != "approval" &&
        !(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
    }

    func upload(data: Data, name: String) async {
        do {
            let r = try await app.client.upload("/api/attachments", query: ["project": agent.project ?? "musa-control", "name": name], data: data, as: [String: String].self)
            if let p = r["path"] { attachments.append((name, p)) }
        } catch { self.error = "Attachment failed: \(error.localizedDescription)" }
    }

    func send() {
        guard canSend else { return }
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !attachments.isEmpty {
            body += "\n\nAttached files:\n" + attachments.map { "- \($0.path)" }.joined(separator: "\n")
        }
        sending = true; error = nil
        Task {
            defer { sending = false }
            do {
                _ = try await app.client.send("POST", "/api/agents/\(agent.id.pathSegment)/send", ["text": body], as: OK.self)
                text = ""; attachments = []
            } catch { self.error = error.localizedDescription }
        }
    }
}
