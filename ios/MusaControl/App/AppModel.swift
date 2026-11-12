import SwiftUI
import Observation
import UIKit

enum AppSection: String, CaseIterable, Identifiable, Codable {
    case home, deck, workspaces, agents, terminal, files, visuals, git, machines, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "Home"; case .deck: return "Command Deck"; case .workspaces: return "Workspaces"; case .agents: return "Agents"; case .terminal: return "Terminal"
        case .files: return "Files"; case .visuals: return "Visuals"; case .git: return "Git & Builds"; case .machines: return "Machines & AI"; case .settings: return "Settings"
        }
    }
    var icon: String {
        switch self {
        case .home: return "square.grid.2x2"; case .deck: return "rectangle.3.group"; case .workspaces: return "rectangle.split.3x1"; case .agents: return "sparkles"; case .terminal: return "terminal"
        case .files: return "folder"; case .visuals: return "photo.on.rectangle.angled"; case .git: return "arrow.triangle.branch"; case .machines: return "desktopcomputer"; case .settings: return "gearshape"
        }
    }
    /// ⌘1…⌘9 for the first nine sections (a two-digit Character would trap).
    var shortcut: KeyEquivalent? {
        let n = AppSection.allCases.firstIndex(of: self)! + 1
        return n <= 9 ? KeyEquivalent(Character(String(n))) : nil
    }
}

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

    // Navigation
    var section: AppSection = .home
    var workspaceProject: String?
    var focusedAgent: String?
    var studioAgent: String?                   // agent whose live studio is open (over the section)
    var filesProject: String?
    var showLauncher = false
    var launcherProject: String?
    var showSwitcher = false
    var pendingTerminalAttach: String?         // tmux session to open in Terminal
    /// Full sidebar vs icon rail on wide windows. The rail is always visible,
    /// so collapsing can never strand navigation, whatever was saved.
    var sidebarExpanded: Bool = UserDefaults.standard.object(forKey: "sidebar.expanded") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sidebarExpanded, forKey: "sidebar.expanded") }
    }
    var sidebarOverlay = false                 // narrow windows: full sidebar over the content (not saved)
    var focusApproval = false                  // opened from an approval notification

    // Follow Agent
    var followAgent: String?                   // agent id, nil = any agent in context
    var followPaused = false
    var followPinned: FollowFocus.View?
    var followFocus: FollowFocus?

    private var refreshTask: Task<Void, Never>?
    private var fixtureStream: Task<Void, Never>?

    init() {
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
        if let s = UserDefaults.standard.string(forKey: "section"), let sec = AppSection(rawValue: s) { section = sec }
        workspaceProject = UserDefaults.standard.string(forKey: "workspaceProject")
        if fx, let i = args.firstIndex(of: "-section"), i + 1 < args.count, let s = AppSection(rawValue: args[i + 1]) { section = s }
        if fx, let i = args.firstIndex(of: "-studio"), i + 1 < args.count { studioAgent = args[i + 1] }
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

    /// Forget the active machine's credentials (the machine itself keeps
    /// running). Falls back to another saved machine, or onboarding.
    func unpair() {
        stream?.stop(); stream = nil
        refreshTask?.cancel()
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
        overview = nil; projects = []; agents = []; liveEvents = []; followFocus = nil; studioAgent = nil; focusedAgent = nil
        workspaceProject = nil; filesProject = nil
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
    func resume() { Task { await connect() } }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                await self?.refreshAgents()
                if self?.section == .home { await self?.refreshOverview() }
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
        if followAgent == nil, let wp = workspaceProject, section == .workspaces, ev.project != wp { return }
        guard let raw = ev.follow?["view"]?.string, let view = FollowFocus.View(rawValue: raw) else { return }
        if let pinned = followPinned, pinned != view { return }
        followFocus = FollowFocus(view: view, event: ev)
    }

    func project(_ id: String?) -> Project? { projects.first { $0.id == id } }
    func agent(_ id: String?) -> Agent? { agents.first { $0.id == id } }

    func go(_ s: AppSection) { studioAgent = nil; section = s; UserDefaults.standard.set(s.rawValue, forKey: "section") }
    func openWorkspace(_ id: String) {
        workspaceProject = id
        UserDefaults.standard.set(id, forKey: "workspaceProject")
        go(.workspaces)
        Task { _ = try? await client.send("POST", "/api/projects/\(id)/watch", ["minutes": 60], as: WatchState.self) }
    }
    func openStudio(_ id: String) { studioAgent = id }
    func openAgent(_ id: String) { focusedAgent = id; go(.agents) }
    func attachTerminal(_ tmux: String) { pendingTerminalAttach = tmux; go(.terminal) }
}
