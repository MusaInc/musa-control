import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import SwiftTerm

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
            // Wide: list beside the conversation. Narrow (portrait split
            // view, Slide Over): one at a time, with a Back button.
            let narrow = geo.size.width < 760
            let listWidth = min(max(geo.size.width * 0.3, 280), 360)
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
                            EmptyNote(icon: "sparkles", text: "Choose an agent", detail: "Every Claude Code and Codex session on the server is listed, including ones started outside Musa Control.")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(Theme.bg)
        .task {
            await app.refreshAgents()
            if app.focusedAgent == nil && UIDevice.current.userInterfaceIdiom == .pad { app.focusedAgent = app.agents.first(where: { $0.isLive })?.id }
        }
    }

    var listColumn: some View {
        @Bindable var app = app
        return VStack(spacing: 0) {
            PanelHeader(icon: "sparkles", title: "Agents", subtitle: "\(app.agents.filter { $0.isLive }.count) running") {
                IconButton(systemName: "plus", help: "New agent task") { app.launcherProject = nil; app.showLauncher = true }
            }
            Picker("Show", selection: $filter) {
                Text("Running").tag("live"); Text("Needs you").tag("attention"); Text("All").tag("all")
            }
            .pickerStyle(.segmented).padding(.horizontal, 10).padding(.vertical, 8)
            List(list, selection: $app.focusedAgent) { a in
                AgentRow(agent: a).tag(a.id)
                    .listRowBackground(app.focusedAgent == a.id ? Theme.hover : Theme.surface)
                    .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
                    .listRowSeparatorTint(Theme.line)
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .overlay { if list.isEmpty { EmptyNote(icon: "sparkles", text: filter == "attention" ? "Nothing needs you" : "No agents", detail: "Start one with New agent task (⇧⌘N).") } }
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
            Button(action: action) { Label(title, systemImage: "chevron.left").font(.system(size: 14, weight: .medium)) }
                .buttonStyle(.plain).foregroundStyle(Theme.accent).keyboardShortcut("[", modifiers: .command)
            Spacer()
        }
        .padding(.horizontal, 12).frame(height: 40).background(Theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

struct AgentDetail: View {
    let agent: Agent
    var onBack: (() -> Void)? = nil
    @Environment(AppModel.self) private var app
    @State private var tab = "activity"
    @State private var confirmEnd = false
    @State private var error: String?
    @State private var titleExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            if let onBack { BackBar(title: "Agents", action: onBack) }
            header
            if let p = agent.approval {
                ApprovalCard(agent: agent, prompt: p).padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(maxWidth: 920).frame(maxWidth: .infinity).background(Theme.bg)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Group {
                switch tab {
                case "screen": AgentScreen(agent: agent)
                case "follow": FollowPanel(agentId: agent.id)
                default: AgentTimeline(agent: agent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(Theme.caption).foregroundStyle(Theme.red).padding(8).frame(maxWidth: .infinity, alignment: .leading) }
            AgentComposer(agent: agent)
        }
        .background(Theme.bg)
        .onAppear { if app.focusApproval { app.focusApproval = false; tab = "activity" } }
        .confirmationDialog("End this \(agent.agentName) session?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End session", role: .destructive) { act { _ = try await app.client.send("POST", "/api/agents/\(agent.id.pathSegment)/end", ["confirm": true], as: OK.self) } }
        } message: { Text("Stops the agent and closes its tmux session. Its transcript and history stay on the server.") }
    }

    /// Hierarchy: project and agent first, then what it's doing now; counts
    /// and ids stay secondary (menu, faint metadata).
    var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: agent.icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(agent.agent == "claude" ? Theme.accent : Theme.blue)
                    .frame(width: 36, height: 36).background(Theme.raised, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if let p = app.project(agent.project) {
                            Button { app.openWorkspace(p.id) } label: { Text(p.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.accent) }.buttonStyle(.plain)
                            Text("·").foregroundStyle(Theme.textFaint)
                        }
                        Text(agent.agentName).font(.system(size: 12.5)).foregroundStyle(Theme.textDim)
                        if let m = agent.model { Text(m).font(.system(size: 12)).foregroundStyle(Theme.textFaint).lineLimit(1) }
                    }
                    Text(agent.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                        .lineLimit(titleExpanded ? 6 : 2).fixedSize(horizontal: false, vertical: true)
                        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { titleExpanded.toggle() } }
                        .accessibilityHint(Text("Shows the full task title"))
                }
                .layoutPriority(1)
                Spacer(minLength: 4)
                HStack(spacing: 2) {
                    if agent.controllable {
                        IconButton(systemName: "stop.circle", help: "Interrupt (Esc)", tint: Theme.yellow) { act { _ = try await app.client.send("POST", "/api/agents/\(agent.id.pathSegment)/interrupt", [:], as: OK.self) } }
                    }
                    moreMenu
                }
            }
            // What it is doing right now.
            HStack(spacing: 8) {
                StatusDot(status: agent.status, size: 8)
                Text(nowText).font(.system(size: 13.5, weight: .medium)).foregroundStyle(agent.status == "approval" ? Theme.yellow : Theme.text).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                Picker("View", selection: $tab) {
                    Text("Activity").tag("activity"); Text("Screen").tag("screen"); Text("Follow").tag("follow")
                }
                .pickerStyle(.segmented).frame(maxWidth: 260)
            }
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 10)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    var nowText: String {
        switch agent.status {
        case "approval": return "Waiting for your approval"
        case "working": return agent.lastEvent.map { stepTitleText($0.title) } ?? "Working"
        case "idle": return "Idle — waiting for instructions"
        case "exited": return "Agent exited (tmux session kept)"
        case "failed": return agent.statusText
        default: return "Not running · last active \(Fmt.ago(agent.lastActivity)) ago"
        }
    }
    func stepTitleText(_ t: String) -> String { t.hasPrefix("$ ") ? "Running " + String(t.dropFirst(2)) : t }

    var moreMenu: some View {
        Menu {
            if let c = agent.counts {
                Section("This session") {
                    Text("\(c.edits) edits · \(c.commands) commands · \(c.images) images\(c.errors > 0 ? " · \(c.errors) errors" : "")")
                }
            }
            if let t = agent.tmux?.session { Button { app.attachTerminal(t) } label: { Label("Open in Terminal", systemImage: "terminal") } }
            Button { app.followAgent = agent.id; app.followPaused = false; app.go(.visuals) } label: { Label("Follow in Visuals", systemImage: "scope") }
            if let p = agent.project { Button { app.openWorkspace(p) } label: { Label("Open workspace", systemImage: "rectangle.split.3x1") } }
            if agent.status == "ended", let sid = agent.sessionId, let p = agent.project {
                Button { act { _ = try await app.client.send("POST", "/api/agents", ["agent": agent.agent, "project": p, "resume": sid], as: LaunchResult.self) } } label: { Label("Resume session", systemImage: "arrow.clockwise") }
            }
            Button { UIPasteboard.general.string = agent.sessionId } label: { Label("Copy session id", systemImage: "doc.on.doc") }
            if agent.managed != nil { Divider(); Button(role: .destructive) { confirmEnd = true } label: { Label("End session…", systemImage: "xmark.circle") } }
        } label: { Image(systemName: "ellipsis.circle").font(.system(size: 16)).foregroundStyle(Theme.textDim).frame(width: 36, height: 36) }
        .accessibilityLabel(Text("More actions"))
    }

    func act(_ f: @escaping () async throws -> Void) {
        Task { do { error = nil; try await f(); await app.refreshAgents() } catch { self.error = error.localizedDescription } }
    }
}

/// The agent's activity as a content-first feed (see ActivityViews). Follows
/// new activity only while you're at the bottom; scrolling up to read stops
/// the auto-scroll until you tap "Latest".
struct AgentTimeline: View {
    let agent: Agent
    @Environment(AppModel.self) private var app
    @State private var events: [TimelineEvent] = []
    @State private var selected: TimelineEvent?
    @State private var following = true
    @State private var loaded = false

    var merged: [TimelineEvent] {
        var seen = Set<String>()
        let live = app.liveEvents.filter { $0.session == agent.id }
        return (events + live).filter { seen.insert($0.stableId).inserted }.sorted { $0.ts < $1.ts }.suffix(500).map { $0 }
    }

    var body: some View {
        let items = merged
        let feed = Feed.build(items)
        let latestMessage = items.last(where: { $0.kind == "agent.message" })?.stableId
        GeometryReader { geo in
            let side = geo.size.width >= 940
            HStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(feed) { entry in
                                FeedEntryView(entry: entry, latestMessageId: latestMessage, select: { selected = $0 }, selectedId: selected?.stableId).id(entry.id)
                            }
                            Color.clear.frame(height: 8).id("bottom")
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .frame(maxWidth: 920, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                    .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { v in if v.translation.height > 12 { following = false } })
                    .onChange(of: items.count) { _, _ in if following { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } } }
                    .onChange(of: loaded) { _, l in if l { proxy.scrollTo("bottom", anchor: .bottom) } }
                    .overlay(alignment: .bottomTrailing) {
                        if !following {
                            Button { following = true; withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } } label: {
                                Label("Latest", systemImage: "arrow.down").font(.system(size: 13, weight: .semibold))
                                    .padding(.horizontal, 12).frame(height: 34)
                                    .background(.regularMaterial, in: Capsule()).overlay(Capsule().stroke(Theme.lineStrong))
                            }
                            .buttonStyle(.plain).padding(14).transition(.opacity)
                        }
                    }
                }
                if side, let s = selected {
                    Rectangle().fill(Theme.line).frame(width: 1)
                    EvidenceView(event: s, close: { selected = nil }).frame(width: min(480, geo.size.width * 0.42))
                }
            }
            .sheet(item: Binding(get: { side ? nil : selected }, set: { selected = $0 })) { s in
                EvidenceView(event: s, close: { selected = nil }).presentationDetents([.medium, .large])
            }
        }
        .overlay {
            if items.isEmpty {
                if loaded { EmptyNote(icon: "text.bubble", text: "No activity yet", detail: "Prompts, replies, commands and results appear here as the agent writes its transcript.") }
                else { ProgressView() }
            }
        }
        .task(id: agent.id) {
            if let e = try? await app.client.get("/api/agents/\(agent.id.pathSegment)/timeline", ["limit": "500"], as: [TimelineEvent].self) { events = e }
            loaded = true
        }
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
            if !controllable {
                EmptyNote(icon: "eye.slash", text: "Not running in tmux", detail: "This session was started outside tmux (e.g. VS Code or a plain terminal), so its screen can't be mirrored. Its activity is still recorded from the transcript.")
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
                ScrollView(.horizontal) { HStack { ForEach(attachments, id: \.path) { a in Pill(text: "📎 " + a.name, color: Theme.accent) } } }
            }
            if let error { Text(error).font(Theme.caption).foregroundStyle(Theme.red) }
            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(selection: $photo, matching: .images) { Image(systemName: "photo").frame(width: 30, height: 34) }
                    .disabled(!agent.controllable)
                Button { importing = true } label: { Image(systemName: "paperclip").frame(width: 30, height: 34) }.buttonStyle(.plain).disabled(!agent.controllable)
                TextField(agent.controllable ? (agent.status == "approval" ? "Answer the prompt above first" : "Instruct \(agent.agentName)…  (⌘↩ to send)") : "Watching only — this session isn't in tmux", text: $text, axis: .vertical)
                    .lineLimit(1...8).font(.system(size: 14.5)).focused($focused)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 9))
                    .disabled(!agent.controllable)
                    .accessibilityIdentifier("agent.composer")
                Button(action: send) {
                    Image(systemName: sending ? "hourglass" : "arrow.up").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.onAccent)
                        .frame(width: 34, height: 34).background(canSend ? Theme.accent : Theme.textFaint, in: Circle())
                }
                .buttonStyle(.plain).disabled(!canSend).keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(10).background(Theme.surface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) { await upload(data: data, name: "image-\(Int(Date().timeIntervalSince1970)).png") }
                photo = nil
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
            guard case .success(let urls) = r else { return }
            Task { for u in urls { let ok = u.startAccessingSecurityScopedResource(); defer { if ok { u.stopAccessingSecurityScopedResource() } }; if let d = try? Data(contentsOf: u) { await upload(data: d, name: u.lastPathComponent) } } }
        }
    }

    var canSend: Bool { agent.controllable && !sending && agent.status != "approval" && !(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty) }

    func upload(data: Data, name: String) async {
        do {
            let r = try await app.client.upload("/api/attachments", query: ["project": agent.project ?? "musa-control", "name": name], data: data, as: [String: String].self)
            if let p = r["path"] { attachments.append((name, p)) }
        } catch { self.error = "Attachment failed: \(error.localizedDescription)" }
    }

    func send() {
        guard canSend else { return }
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !attachments.isEmpty { body += "\n\nAttached files:\n" + attachments.map { "- \($0.path)" }.joined(separator: "\n") }
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
