import SwiftUI

/// Live command centre: everything here comes from /api/overview and the
/// event stream — no placeholder numbers.
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @State private var shot: Screenshot?

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > 900
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if let o = app.overview {
                        HealthStrip(system: o.system)
                        if !o.attention.isEmpty { AttentionList(agents: o.attention) }
                        if wide {
                            HStack(alignment: .top, spacing: 14) {
                                VStack(spacing: 14) { RunningAgents(agents: o.agents); ChangingProjects(items: o.changingProjects) }
                                    .frame(width: geo.size.width * 0.42)
                                VStack(spacing: 14) { ScreenshotStrip(shots: o.screenshots, open: { shot = $0 }); BuildsCard(builds: o.builds); ActivityFeed() }
                            }
                        } else {
                            RunningAgents(agents: o.agents)
                            ScreenshotStrip(shots: o.screenshots, open: { shot = $0 })
                            ChangingProjects(items: o.changingProjects)
                            BuildsCard(builds: o.builds)
                            ActivityFeed()
                        }
                    } else {
                        ProgressView("Loading your server…").frame(maxWidth: .infinity, minHeight: 300)
                    }
                }
                .padding(16)
            }
            .refreshable { await app.refreshAll() }
        }
        .background(Theme.bg)
        .task { await app.refreshOverview() }
        .sheet(item: $shot) { s in ScreenshotViewer(initial: s, all: app.overview?.screenshots ?? [s]) }
    }

    var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(greeting).font(.system(size: 22, weight: .semibold))
                Text(summary).font(.system(size: 13)).foregroundStyle(Theme.textDim)
            }
            Spacer()
            Button { app.showSwitcher = true } label: {
                Label("Jump to…", systemImage: "magnifyingglass").font(Theme.label).padding(.horizontal, 10).frame(height: 32)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).keyboardShortcut("k", modifiers: .command)
            Button { app.launcherProject = nil; app.showLauncher = true } label: {
                Label("New task", systemImage: "plus").font(Theme.label).padding(.horizontal, 12).frame(height: 32)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8)).foregroundStyle(.black)
            }.buttonStyle(.plain).accessibilityIdentifier("home.newTask")
        }
    }

    var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
    }
    var summary: String {
        guard let o = app.overview else { return "Connecting…" }
        let working = o.agents.filter { $0.status == "working" }.count
        let waiting = o.attention.count
        var parts: [String] = []
        parts.append(working == 0 ? "No agents working" : "\(working) agent\(working == 1 ? "" : "s") working")
        if waiting > 0 { parts.append("\(waiting) need\(waiting == 1 ? "s" : "") you") }
        if !o.changingProjects.isEmpty { parts.append("\(o.changingProjects.count) project\(o.changingProjects.count == 1 ? "" : "s") changing") }
        parts.append(o.system.healthy ? "server healthy" : "server needs attention")
        return parts.joined(separator: " · ")
    }
}

struct HealthStrip: View {
    let system: SystemSummary
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 18) {
                HStack(spacing: 6) { StatusDot(status: system.healthy ? "idle" : "failed"); Text(system.healthy ? "Server healthy" : "Server needs attention").font(Theme.label) }
                metric("Load", String(format: "%.2f", system.load.first ?? 0), sub: "\(system.cpus) CPU", warn: (system.load.first ?? 0) > Double(system.cpus))
                metric("Memory", "\(Int((1 - system.memory.available / max(system.memory.total, 1)) * 100))%", sub: Fmt.bytes(system.memory.available) + " free", warn: system.memory.available / max(system.memory.total, 1) < 0.1)
                metric("Disk", "\(Int(system.disk.used / max(system.disk.size, 1) * 100))%", sub: Fmt.bytes(system.disk.available) + " free", warn: system.disk.used / max(system.disk.size, 1) > 0.9)
                metric("Services", "\(system.services.filter { $0.active == "active" }.count)/\(system.services.count)", sub: "running", warn: system.services.contains { $0.active == "failed" })
                metric("Uptime", Fmt.duration(system.uptime), sub: "", warn: false)
                Spacer()
                IconButton(systemName: expanded ? "chevron.up" : "chevron.down", help: "Services") { withAnimation { expanded.toggle() } }
            }
            ForEach(system.issues, id: \.self) { i in Label(i, systemImage: "exclamationmark.triangle.fill").font(Theme.caption).foregroundStyle(Theme.yellow) }
            if expanded {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(system.services) { s in
                        HStack(spacing: 6) { StatusDot(status: s.active == "active" ? "idle" : s.active == "failed" ? "failed" : "other", size: 6); Text(s.name).font(Theme.monoSmall).lineLimit(1); Spacer(); Text(s.sub ?? s.active).font(.system(size: 10)).foregroundStyle(Theme.textFaint) }
                    }
                }
            }
        }
        .card()
    }
    func metric(_ label: String, _ value: String, sub: String, warn: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased()).font(.system(size: 9.5, weight: .semibold)).tracking(0.5).foregroundStyle(Theme.textFaint)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(warn ? Theme.yellow : Theme.text)
                Text(sub).font(.system(size: 10.5)).foregroundStyle(Theme.textFaint)
            }
        }
    }
}

struct AttentionList: View {
    let agents: [Agent]
    @Environment(AppModel.self) private var app
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Needs you", systemImage: "hand.raised.fill").font(Theme.title).foregroundStyle(Theme.yellow)
            ForEach(agents) { a in
                if let p = a.approval {
                    VStack(alignment: .leading, spacing: 6) {
                        Button { app.openAgent(a.id) } label: { AgentRow(agent: a, compact: true) }.buttonStyle(.plain)
                        ApprovalCard(agent: a, prompt: p)
                    }
                } else {
                    Button { app.openAgent(a.id) } label: { AgentRow(agent: a) }.buttonStyle(.plain)
                }
            }
        }
        .card()
    }
}

struct RunningAgents: View {
    let agents: [Agent]
    @Environment(AppModel.self) private var app
    var live: [Agent] { agents.filter { $0.status != "ended" } }
    var recent: [Agent] { agents.filter { $0.status == "ended" }.prefix(4).map { $0 } }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Agents").font(Theme.title)
                Spacer()
                Button("All") { app.go(.agents) }.font(Theme.label)
            }
            if live.isEmpty { Text("No agent is running right now.").font(Theme.caption).foregroundStyle(Theme.textDim).padding(.vertical, 6) }
            ForEach(live) { a in
                Button { app.openAgent(a.id) } label: { AgentRow(agent: a) }.buttonStyle(.plain)
                    .contextMenu { agentMenu(a) }
                Divider().overlay(Theme.line)
            }
            if !recent.isEmpty {
                Text("RECENTLY FINISHED").font(.system(size: 9.5, weight: .semibold)).tracking(0.5).foregroundStyle(Theme.textFaint).padding(.top, 6)
                ForEach(recent) { a in Button { app.openAgent(a.id) } label: { AgentRow(agent: a, compact: true) }.buttonStyle(.plain).contextMenu { agentMenu(a) } }
            }
        }
        .card()
    }
    @ViewBuilder func agentMenu(_ a: Agent) -> some View {
        Button { app.openAgent(a.id) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
        if let p = a.project { Button { app.openWorkspace(p) } label: { Label("Open workspace", systemImage: "rectangle.split.3x1") } }
        if let t = a.tmux?.session { Button { app.attachTerminal(t) } label: { Label("Attach in Terminal", systemImage: "terminal") } }
        Button { app.followAgent = a.id; app.followPaused = false; app.go(.visuals) } label: { Label("Follow this agent", systemImage: "scope") }
    }
}

struct ChangingProjects: View {
    let items: [ChangingProject]
    @Environment(AppModel.self) private var app
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Projects changing").font(Theme.title)
            if items.isEmpty { Text("No file changes in the last hour.").font(Theme.caption).foregroundStyle(Theme.textDim) }
            ForEach(items) { c in
                Button { app.openWorkspace(c.project) } label: {
                    HStack(alignment: .top) {
                        Image(systemName: app.project(c.project)?.icon ?? "folder").frame(width: 18).foregroundStyle(Theme.textDim)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.project(c.project)?.name ?? c.project).font(.system(size: 13, weight: .medium))
                            Text(c.sample.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")).font(Theme.caption).foregroundStyle(Theme.textDim).lineLimit(1)
                        }
                        Spacer()
                        Text("\(c.files) file\(c.files == 1 ? "" : "s") · \(Fmt.ago(c.last))").font(Theme.caption).foregroundStyle(Theme.textFaint)
                    }
                    .padding(.vertical, 4).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct ScreenshotStrip: View {
    let shots: [Screenshot]
    let open: (Screenshot) -> Void
    @Environment(AppModel.self) private var app
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("Latest screenshots").font(Theme.title); Spacer(); Button("Gallery") { app.go(.visuals) }.font(Theme.label) }
            if shots.isEmpty {
                Text("Screenshots agents capture or view in your projects appear here automatically.").font(Theme.caption).foregroundStyle(Theme.textDim)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(shots) { s in
                            Button { open(s) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    AuthImage(path: "/api/screenshots/\(s.id)/image", query: ["w": "480"], contentMode: .fill)
                                        .frame(width: 200, height: 120).clipShape(RoundedRectangle(cornerRadius: 6))
                                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line))
                                    Text(s.name).font(Theme.caption).lineLimit(1).frame(width: 200, alignment: .leading)
                                    Text("\(app.project(s.project)?.name ?? "—") · \(Fmt.ago(s.ts))").font(.system(size: 10)).foregroundStyle(Theme.textFaint)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct BuildsCard: View {
    let builds: [Build]
    @Environment(AppModel.self) private var app
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text("Builds & tests").font(Theme.title); Spacer(); Button("Git & Builds") { app.go(.git) }.font(Theme.label) }
            if builds.isEmpty { Text("Builds you start from a workspace appear here; CI runs are under Git & Builds.").font(Theme.caption).foregroundStyle(Theme.textDim) }
            ForEach(builds.prefix(6)) { b in
                HStack(spacing: 8) {
                    StatusDot(status: b.status)
                    Text(b.label).font(.system(size: 12.5)).lineLimit(1)
                    Text(app.project(b.project)?.name ?? b.project).font(Theme.caption).foregroundStyle(Theme.textFaint)
                    Spacer()
                    Text(b.status == "running" ? "running" : Fmt.ago(b.endedAt ?? b.startedAt)).font(Theme.caption).foregroundStyle(Theme.textFaint)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct ActivityFeed: View {
    @Environment(AppModel.self) private var app
    var events: [TimelineEvent] {
        let important: Set<String> = ["agent.done", "agent.error", "agent.approval", "agent.approval_answered", "build.finished", "ci.finished", "git.commit", "git.push", "screenshot.new", "server.alert", "agent.started", "agent.edit", "agent.test", "agent.command_failed", "agent.prompt"]
        let base = (app.overview?.recent ?? []) + app.liveEvents.filter { important.contains($0.kind) }
        var seen = Set<String>()
        return base.sorted { $0.ts > $1.ts }.filter { seen.insert($0.stableId).inserted }.prefix(40).map { $0 }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Activity").font(Theme.title).padding(.bottom, 4)
            if events.isEmpty { Text("Nothing yet.").font(Theme.caption).foregroundStyle(Theme.textDim) }
            ForEach(events, id: \.stableId) { e in
                Button { open(e) } label: { EventRow(event: e) }.buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
    func open(_ e: TimelineEvent) {
        if let s = e.session { app.openAgent(s) }
        else if let p = e.project { app.openWorkspace(p) }
        else if e.kind.hasPrefix("ci.") || e.kind.hasPrefix("build.") { app.go(.git) }
    }
}
