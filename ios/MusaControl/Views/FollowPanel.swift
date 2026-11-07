import SwiftUI

/// Converts an absolute path from an agent event into (project, relative path).
extension AppModel {
    func locate(_ absolute: String?) -> (project: Project, rel: String)? {
        guard let absolute else { return nil }
        let match = projects.filter { absolute == $0.path || absolute.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count }
        guard let p = match else { return nil }
        return (p, absolute == p.path ? "" : String(absolute.dropFirst(p.path.count + 1)))
    }
}

/// Follow Agent: the visual panel follows what the agent is genuinely doing,
/// driven only by real events. Edits → diff, screenshots → image, browser
/// tools → remote desktop, previews → the app, tests → output, approvals →
/// the approval card. Anything without a visual shows the event itself.
struct FollowPanel: View {
    var agentId: String? = nil       // nil: whatever app.followAgent says (or any agent)
    var project: String? = nil
    @Environment(AppModel.self) private var app

    var target: String? { agentId ?? app.followAgent }
    var focus: FollowFocus? {
        guard let f = app.followFocus else { return nil }
        if let t = target, f.event.session != t { return lastFor(t) }
        if let project, f.event.project != project { return lastFor(nil) }
        return f
    }

    /// Latest followable event in the live buffer for an agent (or project).
    func lastFor(_ session: String?) -> FollowFocus? {
        for e in app.liveEvents.reversed() {
            if let session, e.session != session { continue }
            if session == nil, let project, e.project != project { continue }
            guard let raw = e.follow?["view"]?.string, let v = FollowFocus.View(rawValue: raw) else { continue }
            if let pinned = app.followPinned, pinned != v { continue }
            return FollowFocus(view: v, event: e)
        }
        return nil
    }

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "scope").foregroundStyle(app.followPaused ? Theme.textFaint : Theme.accent)
                Text("Follow Agent").font(.system(size: 12, weight: .semibold))
                if let f = focus {
                    Text("· \(caption(f))").font(Theme.caption).foregroundStyle(Theme.textDim).lineLimit(1)
                }
                Spacer()
                if agentId == nil {
                    Menu {
                        Button { app.followAgent = nil } label: { Label("Any agent\(project != nil ? " in this project" : "")", systemImage: app.followAgent == nil ? "checkmark" : "") }
                        ForEach(app.agents.filter { $0.isLive && (project == nil || $0.project == project) }) { a in
                            Button { app.followAgent = a.id } label: { Label("\(a.agentName): \(a.title)", systemImage: app.followAgent == a.id ? "checkmark" : "") }
                        }
                    } label: { Text(app.agent(app.followAgent)?.title ?? "Any agent").font(Theme.caption).lineLimit(1).frame(maxWidth: 160) }
                }
                Menu {
                    Button { app.followPinned = nil } label: { Label("Switch automatically", systemImage: app.followPinned == nil ? "checkmark" : "") }
                    ForEach([FollowFocus.View.diff, .screenshot, .vnc, .preview, .tests, .approval], id: \.self) { v in
                        Button { app.followPinned = v } label: { Label("Pin: \(v.rawValue)", systemImage: app.followPinned == v ? "checkmark" : "pin") }
                    }
                } label: { Image(systemName: app.followPinned == nil ? "pin" : "pin.fill").frame(width: 28, height: 28) }
                IconButton(systemName: app.followPaused ? "play.fill" : "pause.fill", help: app.followPaused ? "Resume following" : "Pause automatic switching") { app.followPaused.toggle() }
            }
            .padding(.horizontal, 10).frame(height: 34).background(Theme.raised)
            Group {
                if let f = focus {
                    FollowContent(focus: f).id(f.event.stableId)
                } else {
                    EmptyNote(icon: "scope", text: "Waiting for agent activity", detail: "When an agent edits a file, captures a screenshot, drives a browser, runs tests or asks for approval, it shows here.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.2), value: focus?.event.stableId)
        }
        .background(Theme.surface)
    }

    func caption(_ f: FollowFocus) -> String {
        let who = app.agent(f.event.session)?.agentName ?? "Agent"
        return "\(who) · \(f.event.title) · \(Fmt.ago(f.event.ts))"
    }
}

struct FollowContent: View {
    let focus: FollowFocus
    @Environment(AppModel.self) private var app
    var body: some View {
        switch focus.view {
        case .vnc:
            RemoteDesktopPanel(initialDisplay: "99", compact: true)
        case .preview:
            if let p = app.locate(focus.event.detail?["cwd"]?.string)?.project.id ?? focus.event.project {
                PreviewPanel(projectId: p)
            } else { EvidenceView(event: focus.event) }
        case .approval:
            if let a = app.agent(focus.event.session), let p = a.approval { ScrollView { ApprovalCard(agent: a, prompt: p).padding(10) } }
            else { EvidenceView(event: focus.event) }
        default:
            EvidenceView(event: focus.event)
        }
    }
}

/// The underlying evidence for any timeline event.
struct EvidenceView: View {
    let event: TimelineEvent
    var close: (() -> Void)? = nil
    @Environment(AppModel.self) private var app
    @State private var revisionDiff: String?
    @State private var fileText: String?
    @State private var shot: Screenshot?
    @State private var buildLog: String?

    var body: some View {
        VStack(spacing: 0) {
            if let close {
                PanelHeader(icon: event.icon, title: event.title) { IconButton(systemName: "xmark", help: "Close", action: close) }
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.surface)
        .task(id: event.stableId) { await load() }
    }

    var path: String? { event.detail?["path"]?.string }

    @ViewBuilder var content: some View {
        switch event.kind {
        case "agent.edit":
            VStack(spacing: 0) {
                fileBar
                if let d = event.detail?["diff"]?.string, !d.isEmpty { DiffView(diff: d) }
                else if let edits = event.detail?["edits"]?.array, !edits.isEmpty {
                    DiffView(diff: edits.map { DiffParser.fromEdit(old: $0["old"]?.string ?? "", new: $0["new"]?.string ?? "", path: (path as NSString?)?.lastPathComponent ?? "file") }.joined(separator: "\n"))
                } else if let revisionDiff { DiffView(diff: revisionDiff) }
                else if let fileText, let p = path { CodeView(text: fileText, path: p) }
                else { EmptyNote(icon: "doc", text: "Whole-file write", detail: "The agent wrote the file in one go; showing the saved file once it lands.") }
            }
        case "file.changed":
            VStack(spacing: 0) { fileBar; if let revisionDiff { DiffView(diff: revisionDiff, emptyText: "First snapshot of this file") } else { ProgressView().frame(maxHeight: .infinity) } }
        case "agent.image", "screenshot.new":
            if let shot { ScreenshotDetail(shot: shot) } else { EmptyNote(icon: "photo", text: (path as NSString?)?.lastPathComponent ?? "Image", detail: "Loading…") }
        case "agent.command", "agent.command_done", "agent.command_failed", "agent.test":
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("$ " + (event.detail?["command"]?.string ?? "")).font(Theme.mono).foregroundStyle(Theme.accent).textSelection(.enabled)
                    if let code = event.detail?["exitCode"]?.number { Pill(text: "exit \(Int(code))", color: code == 0 ? Theme.green : Theme.red) }
                    Text(event.detail?["output"]?.string ?? "Output arrives when the command finishes.").font(Theme.monoSmall).foregroundStyle(Theme.textDim).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
        case "build.started", "build.finished", "build.cancelled":
            ScrollView { Text(buildLog ?? "Loading log…").font(Theme.monoSmall).foregroundStyle(Theme.textDim).frame(maxWidth: .infinity, alignment: .leading).padding(12).textSelection(.enabled) }
        case "agent.approval":
            ScrollView { Text(event.detail?["context"]?.string ?? event.title).font(Theme.monoSmall).frame(maxWidth: .infinity, alignment: .leading).padding(12).textSelection(.enabled) }
        case "agent.plan":
            List(event.detail?["items"]?.array ?? [], id: \.self) { i in
                Label(i["text"]?.string ?? "", systemImage: i["status"]?.string == "completed" ? "checkmark.circle.fill" : i["status"]?.string == "in_progress" ? "circle.dotted" : "circle")
                    .font(.system(size: 13)).listRowBackground(Theme.surface)
            }.listStyle(.plain).scrollContentBackground(.hidden)
        default:
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(event.detail?["text"]?.string ?? event.detail?["last"]?.string ?? event.title).font(.system(size: 13)).textSelection(.enabled)
                    if let input = event.detail?["input"]?.string { Text(input).font(Theme.monoSmall).foregroundStyle(Theme.textDim).textSelection(.enabled) }
                    Text("No visual output for this step — this is the recorded event.").font(Theme.caption).foregroundStyle(Theme.textFaint)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
        }
    }

    @ViewBuilder var fileBar: some View {
        if let path {
            HStack(spacing: 6) {
                Image(systemName: "doc.text").foregroundStyle(Theme.textDim)
                Text(app.locate(path)?.rel ?? path).font(Theme.monoSmall).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let loc = app.locate(path) {
                    Button("Open") { app.filesProject = loc.project.id; FilesState.shared.open(project: loc.project.id, path: loc.rel); app.go(.files) }.font(Theme.caption)
                }
            }
            .padding(.horizontal, 10).frame(height: 28).background(Theme.bg)
        }
    }

    func load() async {
        switch event.kind {
        case "file.changed":
            if let rev = event.detail?["revision"]?.number, let d = try? await app.client.get("/api/revisions/\(Int(rev))/diff", as: RevisionDiff.self) { revisionDiff = d.diff ?? "" }
        case "agent.edit":
            guard event.detail?["diff"]?.string == nil, event.detail?["edits"]?.array.isEmpty != false, let loc = app.locate(path) else { return }
            // Prefer the watcher's revision diff; fall back to the file itself.
            if let revs = try? await app.client.get("/api/projects/\(loc.project.id)/revisions", ["path": loc.rel], as: [Revision].self), let r = revs.first,
               let d = try? await app.client.get("/api/revisions/\(r.id)/diff", as: RevisionDiff.self), let diff = d.diff { revisionDiff = diff; return }
            if let f = try? await app.client.get("/api/projects/\(loc.project.id)/file", ["path": loc.rel], as: FileContent.self) { fileText = f.text }
        case "screenshot.new":
            if let id = event.detail?["id"]?.number { shot = Screenshot(id: Int(id), ts: event.ts, project: event.project, session: event.session, path: path ?? "", width: event.detail?["width"]?.number.map { Int($0) }, height: event.detail?["height"]?.number.map { Int($0) }, bytes: nil, source: event.detail?["source"]?.string ?? "", note: nil) }
        case "agent.image":
            for _ in 0..<6 {
                if let list = try? await app.client.get("/api/screenshots", ["session": event.session, "limit": "100"], as: [Screenshot].self), let s = list.first(where: { $0.path == path || $0.path.hasSuffix(path ?? "\u{0}") }) { shot = s; return }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        case "build.started", "build.finished", "build.cancelled":
            if let b = event.detail?["build"]?.string, let l = try? await app.client.get("/api/builds/\(b)", as: BuildLog.self) { buildLog = l.text }
        default: break
        }
    }
}
