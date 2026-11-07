import SwiftUI
import Observation
import UIKit

enum AppSection: String, CaseIterable, Identifiable, Codable {
    case home, workspaces, agents, terminal, files, visuals, git, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "Home"; case .workspaces: return "Workspaces"; case .agents: return "Agents"; case .terminal: return "Terminal"
        case .files: return "Files"; case .visuals: return "Visuals"; case .git: return "Git & Builds"; case .settings: return "Settings"
        }
    }
    var icon: String {
        switch self {
        case .home: return "square.grid.2x2"; case .workspaces: return "rectangle.split.3x1"; case .agents: return "sparkles"; case .terminal: return "terminal"
        case .files: return "folder"; case .visuals: return "photo.on.rectangle.angled"; case .git: return "arrow.triangle.branch"; case .settings: return "gearshape"
        }
    }
    var shortcut: KeyEquivalent { KeyEquivalent(Character(String(AppSection.allCases.firstIndex(of: self)! + 1))) }
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

    init() {
        let args = ProcessInfo.processInfo.arguments
        let fx = args.contains("-UITestFixtures")
        fixtures = fx
        let stored = UserDefaults.standard.string(forKey: "serverURL") ?? "https://musastudios.co.uk/control"
        let url = URL(string: stored) ?? URL(string: "https://musastudios.co.uk/control")!
        serverURL = url
        let token = fx ? "fixture" : Keychain.string("deviceToken")
        client = GatewayClient(base: url, token: token, transport: fx ? FixtureTransport() : nil)
        if let s = UserDefaults.standard.string(forKey: "section"), let sec = AppSection(rawValue: s) { section = sec }
        workspaceProject = UserDefaults.standard.string(forKey: "workspaceProject")
        if fx, let i = args.firstIndex(of: "-section"), i + 1 < args.count, let s = AppSection(rawValue: args[i + 1]) { section = s }
        if token != nil { phase = .connecting }
    }

    var isPaired: Bool { client.token != nil }

    // MARK: Pairing

    func pair(server: String, password: String) async throws {
        guard let url = URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https" || fixtures else {
            throw GatewayError(status: 0, message: "Use the https:// address of the gateway.", body: nil)
        }
        let tmp = GatewayClient(base: url, token: nil)
        let body = try JSONSerialization.data(withJSONObject: ["password": password, "deviceName": UIDevice.current.name])
        let d = try await tmp.raw(tmp.request("POST", "/api/pair", body: body))
        let r = try JSONDecoder().decode(PairResponse.self, from: d)
        Keychain.setString(r.token, for: "deviceToken")
        UserDefaults.standard.set(url.absoluteString, forKey: "serverURL")
        serverURL = url
        client = GatewayClient(base: url, token: r.token)
        phase = .connecting
        await connect()
    }

    func unpair() {
        Keychain.delete("deviceToken")
        stream?.stop(); stream = nil
        refreshTask?.cancel()
        client = GatewayClient(base: serverURL, token: nil)
        overview = nil; projects = []; agents = []
        phase = .unpaired
    }

    // MARK: Connection

    func connect() async {
        guard isPaired else { phase = .unpaired; return }
        if phase != .ready { phase = .connecting }
        do {
            _ = try await client.get("/api/me", as: Me.self)
            phase = .ready
            await refreshAll()
            startStream()
            startRefreshLoop()
            if !fixtures { Task { await Notifier.shared.syncRegistration() } }
        } catch let e as GatewayError where e.isAuth {
            unpair()
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
            Task {
                let evs = (try? await client.get("/api/timeline", as: [TimelineEvent].self)) ?? []
                for e in evs.sorted(by: { $0.ts < $1.ts }) { receive(e) }
                banner = nil
            }
            return
        }
        stream?.stop()
        let s = EventStream(client: client, lastId: UserDefaults.standard.string(forKey: "lastEventId"))
        s.onEvent = { [weak self] ev in self?.receive(ev) }
        s.onState = { [weak self] st in
            self?.streamState = st
            if st == .retrying(-1) { self?.unpair() }
        }
        stream = s
        s.start()
    }

    func suspend() { stream?.stop(); refreshTask?.cancel() }
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
        if let id = ev.id { UserDefaults.standard.set(String(id), forKey: "lastEventId") }
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

    func go(_ s: AppSection) { section = s; UserDefaults.standard.set(s.rawValue, forKey: "section") }
    func openWorkspace(_ id: String) {
        workspaceProject = id
        UserDefaults.standard.set(id, forKey: "workspaceProject")
        go(.workspaces)
        Task { _ = try? await client.send("POST", "/api/projects/\(id)/watch", ["minutes": 60], as: WatchState.self) }
    }
    func openAgent(_ id: String) { focusedAgent = id; go(.agents) }
    func attachTerminal(_ tmux: String) { pendingTerminalAttach = tmux; go(.terminal) }
}
