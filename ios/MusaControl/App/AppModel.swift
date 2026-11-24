import SwiftUI
import Observation
import UIKit

/// Places the app can take you. Everything except Machines & AI and
/// Settings opens inside the one workspace (a panel, the navigator or the
/// remote desktop); those two open as sheets over it.
enum AppSection: String, CaseIterable, Identifiable, Codable {
    case workspace, agents, terminal, files, visuals, git, desktop, machines, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .workspace: return "Workspace"; case .agents: return "Agents"; case .terminal: return "Terminal"; case .files: return "Files"
        case .visuals: return "Visualiser"; case .git: return "Source Control"; case .desktop: return "Remote Desktop"
        case .machines: return "Machines & AI"; case .settings: return "Settings"
        }
    }
    var icon: String {
        switch self {
        case .workspace: return "rectangle.split.3x1"; case .agents: return "sparkles"; case .terminal: return "terminal"; case .files: return "folder"
        case .visuals: return "chart.xyaxis.line"; case .git: return "arrow.triangle.branch"; case .desktop: return "display"
        case .machines: return "desktopcomputer"; case .settings: return "gearshape"
        }
    }
}

enum AppSheet: String, Identifiable { case machines, settings; var id: String { rawValue } }
enum PhoneTab: String, CaseIterable { case workspace, agents, desktop, more }

/// What the Follow Agent panel should show, derived only from real events.
struct FollowFocus: Equatable {
    enum View: String { case diff, file, screenshot, vnc, preview, tests, approval, build, activity }
    var view: View
    var event: TimelineEvent
    var path: String? { event.follow?["path"]?.string ?? event.detail?["path"]?.string }
}

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable { case unpaired, connecting, ready, offline(String) }

    // Machines (see Core/Machines.swift)
    var machines: [Machine] = []
    var activeMachine: Machine?
    var showAddMachine = false

    // Connection
    var serverURL: URL
    var phase: Phase = .unpaired
    var streamState: EventStream.State = .idle
    private(set) var client: GatewayClient
    private var stream: EventStream?
    let fixtures: Bool

    // Data
    var overview: Overview?
    var projects: [Project] = []
    var agents: [Agent] = []
    var liveEvents: [TimelineEvent] = []      // newest last, bounded
    var eventTick = 0                          // bumps on every live event
    var banner: TimelineEvent?

    // Navigation: one workspace, one desktop, sheets for the rest.
    let workspace: WorkspaceStore
    let desktop: DesktopStore
    var sheet: AppSheet?
    var phoneTab: PhoneTab = .workspace
    var workspaceProject: String? { workspace.projectId }
    var focusedAgent: String?
    var filesProject: String?
    var showLauncher = false
    var launcherProject: String?
    var showSwitcher = false
    var showQuickOpen = false
    var focusApproval = false                  // opened from an approval notification

    // Follow Agent
    var followAgent: String?                   // agent id, nil = any agent in context
    var followPaused = false
    var followPinned: FollowFocus.View?
    var followFocus: FollowFocus?

    @ObservationIgnored var pendingPreset: WorkspaceLayout.Preset?
    private var refreshTask: Task<Void, Never>?
    private var fixtureStream: Task<Void, Never>?

    init() {
        workspace = WorkspaceStore()
        desktop = DesktopStore()
        let args = ProcessInfo.processInfo.arguments
        let fx = args.contains("-UITestFixtures")
        fixtures = fx
        if !fx { MachineStore.migrateIfNeeded() }
        // UI tests: -onboarding shows the first-run screens (no machine yet).
        let onboarding = fx && args.contains("-onboarding")
        let active = onboarding ? nil : fx ? Machine(id: Machine.personalId, name: "Musa Studios VPS", kind: .direct, url: "https://musastudios.co.uk/control", platform: "linux", addedAt: 0) : MachineStore.active
        machines = onboarding ? [] : fx ? [active!] : MachineStore.all
        activeMachine = active
        let stored = active?.url ?? UserDefaults.standard.string(forKey: "serverURL") ?? "https://musastudios.co.uk/control"
        let url = URL(string: stored) ?? URL(string: "https://musastudios.co.uk/control")!
        serverURL = url
        let token = onboarding ? nil : fx ? "fixture" : active?.token
        // SSH machines get their real (tunnel) address in connect().
        let base = active?.kind == .relay ? CloudAuth.machineBase(active?.cloudId ?? "") : url
        client = GatewayClient(base: base, token: token, transport: fx ? FixtureTransport() : nil)
        if fx, let i = args.firstIndex(of: "-project"), i + 1 < args.count { workspace.open(project: args[i + 1]) }
        if fx, let i = args.firstIndex(of: "-sheet"), i + 1 < args.count { sheet = AppSheet(rawValue: args[i + 1]) }
        if fx, let i = args.firstIndex(of: "-preset"), i + 1 < args.count, let p = WorkspaceLayout.Preset(rawValue: args[i + 1]) { pendingPreset = p }
        if token != nil { phase = .connecting }
    }

    var isPaired: Bool { client.token != nil || activeMachine?.kind == .ssh }
    private var lastEventKey: String { MachineStore.scoped("lastEventId", activeMachine?.id) }

    // MARK: Pairing

    func pair(server: String, password: String) async throws {
        guard let url = URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https" || fixtures else {
            throw GatewayError(status: 0, message: "Use the https:// address of the gateway.", body: nil)
        }
        let tmp = GatewayClient(base: url, token: nil)
        let body = try JSONSerialization.data(withJSONObject: ["password": password, "deviceName": UIDevice.current.name])
        let d = try await tmp.raw(tmp.request("POST", "/api/pair", body: body))
        let r = try JSONDecoder().decode(PairResponse.self, from: d)
        // A password-paired gateway is the personal machine (one per app).
        let m = Machine(id: Machine.personalId, name: "Musa Studios VPS", kind: .direct, url: url.absoluteString, platform: "linux", addedAt: Date().timeIntervalSince1970)
        Keychain.setString(r.token, for: m.tokenKey)
        UserDefaults.standard.set(url.absoluteString, forKey: "serverURL")
        UserDefaults.standard.set(true, forKey: "machines.migrated")
        MachineStore.upsert(m)
        await activate(m)
    }

    /// Hosted workspaces get their own Keychain entry; never replace the studio connection.
    func pairHosted(server: String, code: String, name: String) async throws {
        let url = try HostedConnection.url(server)
        let tmp = GatewayClient(base: url, token: nil)
        let response = try await tmp.send("POST", "/api/pair", ["code": code, "deviceName": UIDevice.current.name], as: PairResponse.self)
        let existing = MachineStore.all.first { !$0.isPersonal && $0.kind == .direct && $0.url == url.absoluteString }
        let machine = Machine(id: existing?.id ?? UUID().uuidString, name: name.isEmpty ? "My workspace" : name, kind: .direct,
                              url: url.absoluteString, platform: "linux", addedAt: Date().timeIntervalSince1970)
        Keychain.setString(response.token, for: machine.tokenKey)
        MachineStore.upsert(machine)
        await activate(machine)
    }

    /// Forget the active machine's credentials (the machine itself keeps
    /// running). Falls back to another saved machine, or onboarding.
    func unpair() {
        stream?.stop(); stream = nil
        refreshTask?.cancel()
        desktop.teardown()
        if let m = activeMachine, m.kind != .relay {
            MachineStore.remove(m.id)
            SSHTunnels.shared.drop(m.id)
        }
        machines = MachineStore.all
        overview = nil; projects = []; agents = []; liveEvents = []
        if let next = machines.first(where: { $0.id != activeMachine?.id }) ?? machines.first, next.id != activeMachine?.id {
            Task { await activate(next) }
            return
        }
        activeMachine = nil
        client = GatewayClient(base: serverURL, token: nil)
        phase = .unpaired
    }

    // MARK: Machines

    func reloadMachines() {
        machines = MachineStore.all
        guard let id = activeMachine?.id else { return }
        if let m = machines.first(where: { $0.id == id }) { activeMachine = m; return }
        // The active computer went away (unlinked, account deleted or signed out).
        if let next = machines.first { Task { await activate(next) } }
        else { stream?.stop(); stream = nil; refreshTask?.cancel(); activeMachine = nil; client = GatewayClient(base: serverURL, token: nil); phase = .unpaired }
    }

    /// Switch everything (data, live stream, terminals, web views) to another machine.
    func activate(_ m: Machine) async {
        stream?.stop(); stream = nil
        refreshTask?.cancel()
        MachineStore.activeId = m.id
        machines = MachineStore.all
        activeMachine = m
        overview = nil; projects = []; agents = []; liveEvents = []; followFocus = nil; focusedAgent = nil
        desktop.teardown()
        workspace.open(project: nil); filesProject = nil
        if let u = m.url, let url = URL(string: u) { serverURL = url }
        client = GatewayClient(base: m.kind == .relay ? CloudAuth.machineBase(m.cloudId ?? "") : (URL(string: m.url ?? "") ?? serverURL), token: m.token)
        WebSessionCookie.reset()
        TerminalStore.shared.switchMachine(m.id)
        phase = .connecting
        await connect()
    }

    func removeMachine(_ m: Machine) async {
        if m.kind == .relay, let cid = m.cloudId { try? await Account.shared.removeMachine(cid) }
        MachineStore.remove(m.id)
        SSHTunnels.shared.drop(m.id)
        machines = MachineStore.all
        if activeMachine?.id == m.id {
            if let next = machines.first { await activate(next) } else { activeMachine = nil; client = GatewayClient(base: serverURL, token: nil); phase = .unpaired }
        }
    }

    func renameMachine(_ m: Machine, to name: String) async {
        var x = m; x.name = name
        if m.kind == .relay, let cid = m.cloudId { try? await Account.shared.renameMachine(cid, name) }
        MachineStore.upsert(x)
        reloadMachines()
    }

    // MARK: Connection

    func connect() async {
        guard isPaired else { phase = activeMachine == nil && machines.isEmpty ? .unpaired : .offline("Sign in again to reach \(activeMachine?.name ?? "this machine")."); return }
        if phase != .ready { phase = .connecting }
        do {
            // SSH machines: (re)open the tunnel and talk to the companion through it.
            if !fixtures, let m = activeMachine, m.kind == .ssh {
                let p = try await SSHTunnels.shared.port(for: m)
                if client.base.port != p { client = GatewayClient(base: URL(string: "http://127.0.0.1:\(p)")!, token: m.token) }
            }
            _ = try await client.get("/api/me", as: Me.self)
            phase = .ready
            await refreshAll()
            if workspace.projectId == nil || project(workspace.projectId) == nil, let first = projects.first(where: { ($0.activeAgents ?? 0) > 0 }) ?? projects.first { workspace.open(project: first.id) }
            if let p = pendingPreset { workspace.apply(p); pendingPreset = nil }
            if !fixtures, desktop.wasActive, !desktop.active { desktop.open(client: client, machine: activeMachine?.id) }
            startStream()
            startRefreshLoop()
            if !fixtures { Task { await Notifier.shared.syncRegistration() } }
        } catch let e as GatewayError where e.isAuth {
            if activeMachine?.kind == .relay { Account.shared.signOutLocally(); reloadMachines(); phase = .offline("Your Musa Control session ended. Sign in again in Machines & AI.") }
            else { unpair() }
        } catch {
            phase = .offline(error.localizedDescription)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, case .offline = self.phase else { return }
                Task { await self.connect() }
            }
        }
    }

    func startStream() {
        guard !fixtures else {
            // UI tests: replay the sample timeline through the same path live events take.
            streamState = .live
            fixtureStream?.cancel()
            fixtureStream = Task {
                let evs = (try? await client.get("/api/timeline", as: [TimelineEvent].self)) ?? []
                for e in evs.sorted(by: { $0.ts < $1.ts }) { receive(e) }
                banner = nil
                await replayFixtureLive()
            }
            return
        }
        stream?.stop()
        let s = EventStream(client: client, lastId: UserDefaults.standard.string(forKey: lastEventKey))
        s.onEvent = { [weak self] ev in self?.receive(ev) }
        s.onState = { [weak self] st in
            self?.streamState = st
            if st == .retrying(-1) { self?.unpair() }
        }
        stream = s
        s.start()
    }

    func suspend() { stream?.stop(); refreshTask?.cancel(); fixtureStream?.cancel() }
    func resume() { Task { await connect(); desktop.resume() } }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                await self?.refreshAgents()
            }
        }
    }

    func refreshAll() async {
        async let a: () = refreshProjects()
        async let b: () = refreshAgents()
        async let c: () = refreshOverview()
        _ = await (a, b, c)
    }
    func refreshProjects() async { if let p = try? await client.get("/api/projects", as: [Project].self) { projects = p } }
    func refreshAgents() async { if let a = try? await client.get("/api/agents", as: [Agent].self) { agents = a } }
    func refreshOverview() async { if let o = try? await client.get("/api/overview", as: Overview.self) { overview = o } }

    // MARK: Events

    private func receive(_ ev: TimelineEvent) {
        if let id = ev.id { UserDefaults.standard.set(String(id), forKey: lastEventKey) }
        liveEvents.append(ev)
        if liveEvents.count > 600 { liveEvents.removeFirst(liveEvents.count - 600) }
        eventTick &+= 1
        updateFollow(with: ev)
        // An agent driving the browser: bring the desktop up (never steals
        // the screen: it opens floating, or grows from the mini thumbnail).
        if !fixtures, ev.follow?["view"]?.string == "vnc", desktop.followAgents, !followPaused,
           workspace.projectId == nil || ev.project == nil || ev.project == workspace.projectId {
            showDesktop(follow: true)
        }
        if ev.kind.hasPrefix("agent.approval") || ev.kind == "agent.started" || ev.kind == "agent.ended" || ev.kind == "agent.done" {
            Task { await refreshAgents() }
        }
        if ev.notify == 1 {
            Notifier.shared.deliver(ev, foreground: UIApplication.shared.applicationState == .active)
            if UIApplication.shared.applicationState == .active { banner = ev }
        }
    }

    /// UI tests / offline demo: replays the recorded session in
    /// Fixtures/live.json through the live path, in a loop, stamped with the
    /// current time, so the deck and studio have something real to show.
    private struct LiveStep: Decodable { let after: Double; let event: TimelineEvent? }
    private func replayFixtureLive() async {
        guard fixtures, !ProcessInfo.processInfo.arguments.contains("-noLive"),
              let u = Bundle.main.url(forResource: "live", withExtension: "json", subdirectory: "Fixtures"),
              let d = try? Data(contentsOf: u), let steps = try? JSONDecoder().decode([LiveStep].self, from: d), !steps.isEmpty else { return }
        var n = 0
        while !Task.isCancelled {
            for s in steps {
                try? await Task.sleep(nanoseconds: UInt64(s.after * 1_000_000_000))
                guard let e = s.event else { continue }
                n += 1
                receive(TimelineEvent(id: 500_000 + n, ts: Date().timeIntervalSince1970 * 1000, kind: e.kind, project: e.project,
                                      session: e.session, title: e.title, detail: e.detail, notify: 0))
            }
        }
    }

    func updateFollow(with ev: TimelineEvent) {
        guard !followPaused, let session = ev.session else { return }
        if let followAgent, followAgent != session { return }
        if followAgent == nil, let wp = workspaceProject, ev.project != wp { return }
        guard let raw = ev.follow?["view"]?.string, let view = FollowFocus.View(rawValue: raw) else { return }
        if let pinned = followPinned, pinned != view { return }
        followFocus = FollowFocus(view: view, event: ev)
    }

    func project(_ id: String?) -> Project? { projects.first { $0.id == id } }
    func agent(_ id: String?) -> Agent? { agents.first { $0.id == id } }

    // MARK: Navigation (everything opens inside the workspace)

    func go(_ s: AppSection) {
        switch s {
        case .machines: sheet = .machines; return
        case .settings: sheet = .settings; return
        default: sheet = nil
        }
        switch s {
        case .workspace: phoneTab = .workspace
        case .agents:
            if Device.isPhone { phoneTab = .agents } else { workspace.navigator = .agents; workspace.navigatorVisible = true }
        case .terminal: phoneTab = .workspace; workspace.reveal(.terminal)
        case .files: phoneTab = .workspace; workspace.navigator = .files; workspace.navigatorVisible = true; workspace.reveal(.editor)
        case .visuals: phoneTab = .workspace; workspace.reveal(.visualiser)
        case .git: phoneTab = .workspace; workspace.navigator = .git; workspace.navigatorVisible = true
        case .desktop: showDesktop(follow: false)
        case .machines, .settings: break
        }
    }

    func openWorkspace(_ id: String) {
        workspace.open(project: id)
        phoneTab = .workspace; sheet = nil
        Task { _ = try? await client.send("POST", "/api/projects/\(id)/watch", ["minutes": 60], as: WatchState.self) }
    }

    /// Open a file in the editor panel (switching project if needed).
    func openFile(project: String, path: String, line: Int? = nil) {
        if workspace.projectId != project { openWorkspace(project) }
        filesProject = project
        FilesState.shared.open(project: project, path: path, line: line)
        phoneTab = .workspace; sheet = nil
        workspace.reveal(.editor)
    }

    /// Show a tmux session (an agent's, a build's, a login) in a terminal
    /// panel; nil opens a new shell.
    func showTerminal(tmux: String?, title: String? = nil) {
        phoneTab = .workspace; sheet = nil
        if let tmux {
            var cfg = ["tmux": tmux]
            if let title { cfg["title"] = title }
            workspace.reveal(.terminal, config: cfg) { $0.config["tmux"] == tmux }
        } else {
            workspace.add(.terminal, beside: workspace.layout.slots.first { $0.kind == .terminal }?.id)
        }
    }

    /// The agent's live panel, in its project's workspace.
    func showAgent(_ id: String) {
        if let p = agent(id)?.project, p != workspace.projectId, project(p) != nil { openWorkspace(p) }
        phoneTab = .workspace; sheet = nil
        workspace.reveal(.agent, config: ["agent": id]) { $0.config["agent"] == id || $0.config["agent"] == nil }
    }

    func showDesktop(follow: Bool) {
        if !desktop.active {
            desktop.open(client: client, machine: activeMachine?.id, presentation: follow && !Device.isPhone ? .floating : nil)
        } else if desktop.presentation == .mini {
            desktop.presentation = .floating
        }
        if Device.isPhone && !follow { phoneTab = .desktop }
    }

    func toggleDesktop() { if desktop.active { desktop.close() } else { showDesktop(follow: false) } }

    func openAgent(_ id: String) {
        if Device.isPhone { focusedAgent = id; phoneTab = .agents; sheet = nil } else { showAgent(id) }
    }
    func attachTerminal(_ tmux: String) { showTerminal(tmux: tmux) }
}
