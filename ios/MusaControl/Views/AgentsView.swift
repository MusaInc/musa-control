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
        @Bindable var app = app
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                PanelHeader(icon: "sparkles", title: "Agents", subtitle: "\(app.agents.filter { $0.isLive }.count) running") {
                    IconButton(systemName: "plus", help: "New agent task") { app.launcherProject = nil; app.showLauncher = true }
                }
                Picker("", selection: $filter) {
                    Text("Running").tag("live"); Text("Needs you").tag("attention"); Text("All").tag("all")
                }
                .pickerStyle(.segmented).padding(8)
                List(list, selection: $app.focusedAgent) { a in
                    AgentRow(agent: a).tag(a.id)
                        .listRowBackground(app.focusedAgent == a.id ? Theme.hover : Theme.surface)
                        .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
                .overlay { if list.isEmpty { EmptyNote(icon: "sparkles", text: filter == "attention" ? "Nothing needs you" : "No agents", detail: "Start one with New task (⇧⌘N).") } }
                .refreshable { await app.refreshAgents() }
            }
            .frame(width: 320).background(Theme.surface)
            Divider().overlay(Theme.line)
            if let id = app.focusedAgent, let a = app.agent(id) {
                AgentDetail(agent: a).id(a.id)
            } else {
                EmptyNote(icon: "sparkles", text: "Choose an agent", detail: "Every Claude Code and Codex session on the server is listed, including ones started outside Musa Control.")
            }
        }
        .background(Theme.bg)
        .task { await app.refreshAgents(); if app.focusedAgent == nil { app.focusedAgent = app.agents.first(where: { $0.isLive })?.id } }
    }
}

struct AgentDetail: View {
    let agent: Agent
    @Environment(AppModel.self) private var app
    @State private var tab = "activity"
    @State private var confirmEnd = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            if let p = agent.approval { ApprovalCard(agent: agent, prompt: p).padding(10) }
            Picker("", selection: $tab) {
                Text("Activity").tag("activity")
                Text("Screen").tag("screen")
                Text("Follow").tag("follow")
            }
            .pickerStyle(.segmented).padding(.horizontal, 10).padding(.vertical, 6)
            Group {
                switch tab {
                case "screen": AgentScreen(agent: agent)
                case "follow": FollowPanel(agentId: agent.id)
                default: AgentTimeline(agent: agent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error { Text(error).font(Theme.caption).foregroundStyle(Theme.red).padding(6) }
            AgentComposer(agent: agent)
        }
        .background(Theme.surface)
        .confirmationDialog("End this \(agent.agentName) session?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End session", role: .destructive) { act { _ = try await app.client.send("POST", "/api/agents/\(agent.id.pathSegment)/end", ["confirm": true], as: OK.self) } }
        } message: { Text("Stops the agent and closes its tmux session. Its transcript and history stay on the server.") }
    }

    var header: some View {
        HStack(spacing: 10) {
            Image(systemName: agent.icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(agent.agent == "claude" ? Theme.accent : Theme.blue)
                .frame(width: 34, height: 34).background(Theme.hover, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    StatusDot(status: agent.status)
                    Text(agent.statusText).lineLimit(1).truncationMode(.tail)
                    Text("·"); Text(agent.agentName)
                    if let m = agent.model { Text("·"); Text(m) }
                    if let p = app.project(agent.project) { Text("·"); Button(p.name) { app.openWorkspace(p.id) }.buttonStyle(.plain).foregroundStyle(Theme.accent) }
                }
                .font(Theme.caption).foregroundStyle(Theme.textDim).lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            if let c = agent.counts {
                ViewThatFits {
                    HStack(spacing: 10) {
                    Label("\(c.edits)", systemImage: "pencil.line"); Label("\(c.commands)", systemImage: "terminal"); Label("\(c.images)", systemImage: "photo")
                    if c.errors > 0 { Label("\(c.errors)", systemImage: "exclamationmark.triangle").foregroundStyle(Theme.red) }
                }
                    .font(Theme.caption).foregroundStyle(Theme.textDim).labelStyle(.titleAndIcon)
                    EmptyView()
                }
            }
            if agent.controllable {
                IconButton(systemName: "stop.circle", help: "Interrupt (Esc)", tint: Theme.yellow) { act { _ = try await app.client.send("POST", "/api/agents/\(agent.id.pathSegment)/interrupt", [:], as: OK.self) } }
                if let t = agent.tmux?.session { IconButton(systemName: "terminal", help: "Open in Terminal") { app.attachTerminal(t) } }
            }
            Menu {
                Button { app.followAgent = agent.id; app.followPaused = false; app.go(.visuals) } label: { Label("Follow in Visuals", systemImage: "scope") }
                if let p = agent.project { Button { app.openWorkspace(p) } label: { Label("Open workspace", systemImage: "rectangle.split.3x1") } }
                if agent.status == "ended", let sid = agent.sessionId, let p = agent.project {
                    Button { act { _ = try await app.client.send("POST", "/api/agents", ["agent": agent.agent, "project": p, "resume": sid], as: LaunchResult.self) } } label: { Label("Resume session", systemImage: "arrow.clockwise") }
                }
                if agent.managed != nil { Button(role: .destructive) { confirmEnd = true } label: { Label("End session…", systemImage: "xmark.circle") } }
                Button { UIPasteboard.general.string = agent.sessionId } label: { Label("Copy session id", systemImage: "doc.on.doc") }
            } label: { Image(systemName: "ellipsis.circle").frame(width: 30, height: 30) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.raised)
    }

    func act(_ f: @escaping () async throws -> Void) {
        Task { do { error = nil; try await f(); await app.refreshAgents() } catch { self.error = error.localizedDescription } }
    }
}

/// Structured activity from the agent's transcript, live.
struct AgentTimeline: View {
    let agent: Agent
    @Environment(AppModel.self) private var app
    @State private var events: [TimelineEvent] = []
    @State private var selected: TimelineEvent?

    var merged: [TimelineEvent] {
        var seen = Set<String>()
        let live = app.liveEvents.filter { $0.session == agent.id }
        return (events + live).filter { seen.insert($0.stableId).inserted }.sorted { $0.ts < $1.ts }.suffix(400).map { $0 }
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(merged, id: \.stableId) { e in
                            ActivityItem(event: e, selected: selected?.stableId == e.stableId).id(e.stableId)
                                .onTapGesture { selected = e }
                        }
                    }
                    .padding(10)
                }
                .onChange(of: merged.count) { _, _ in if let l = merged.last { withAnimation { proxy.scrollTo(l.stableId, anchor: .bottom) } } }
                .onAppear { if let l = merged.last { proxy.scrollTo(l.stableId, anchor: .bottom) } }
            }
            if let s = selected {
                Divider().overlay(Theme.line)
                EvidenceView(event: s, close: { selected = nil }).frame(width: 440)
            }
        }
        .overlay { if merged.isEmpty { EmptyNote(icon: "text.bubble", text: "No activity recorded yet", detail: "Events appear as the agent writes its transcript.") } }
        .task(id: agent.id) {
            if let e = try? await app.client.get("/api/agents/\(agent.id.pathSegment)/timeline", ["limit": "400"], as: [TimelineEvent].self) { events = e }
        }
    }
}

/// One activity entry; prompts and messages read like a conversation, tool
/// actions are compact.
struct ActivityItem: View {
    let event: TimelineEvent
    var selected = false
    var body: some View {
        switch event.kind {
        case "agent.prompt", "agent.instruction":
            Text(event.detail?["text"]?.string ?? event.title).font(.system(size: 13)).textSelection(.enabled)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 9)).padding(.vertical, 6)
        case "agent.message":
            Text(LocalizedStringKey(String((event.detail?["text"]?.string ?? event.title).prefix(4000)))).font(.system(size: 13)).textSelection(.enabled)
                .padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
        default:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: event.icon).font(.system(size: 11)).foregroundStyle(event.tint == "other" ? Theme.textFaint : Theme.status(event.tint)).frame(width: 16)
                Text(event.title).font(event.kind.contains("command") || event.kind == "agent.test" ? Theme.monoSmall : .system(size: 12)).foregroundStyle(Theme.textDim).lineLimit(2)
                Spacer(minLength: 0)
                Text(Fmt.time(event.ts)).font(.system(size: 10)).foregroundStyle(Theme.textFaint)
            }
            .padding(.vertical, 3).padding(.horizontal, 4)
            .background(selected ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
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
        v.nativeBackgroundColor = UIColor(red: 0.059, green: 0.063, blue: 0.071, alpha: 1)
        v.nativeForegroundColor = UIColor(red: 0.886, green: 0.894, blue: 0.910, alpha: 1)
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
                    .lineLimit(1...8).font(.system(size: 13.5)).focused($focused)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 9))
                    .disabled(!agent.controllable)
                    .accessibilityIdentifier("agent.composer")
                Button(action: send) {
                    Image(systemName: sending ? "hourglass" : "arrow.up").font(.system(size: 14, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 34, height: 34).background(canSend ? Theme.accent : Theme.textFaint, in: Circle())
                }
                .buttonStyle(.plain).disabled(!canSend).keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(10).background(Theme.raised)
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
