import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Keychain.migrateAccessibility("deviceToken")
        Notifier.shared.setup()
        Task { await Notifier.shared.registerIfAllowed() }
        return true
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Notifier.shared.didRegister(deviceToken: deviceToken)
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Notifier.shared.didFailToRegister(error)
    }
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        await Notifier.shared.handleRemote(userInfo)
    }
}

@main
struct MusaControlApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var app = AppModel()
    @State private var terminals = TerminalStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearance = "system"

    var body: some Scene {
        WindowGroup {
            RootView()
                .overlay { LockOverlay() }
                .environment(app)
                .environment(app.desktop)
                .environment(terminals)
                .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
                .tint(Theme.accent)
                .task {
                    if app.isPaired { await app.connect() }
                    if CloudAuth.token != nil { await Account.shared.refresh(); app.reloadMachines() }
                }
                .onReceive(NotificationCenter.default.publisher(for: .openFromNotification)) { n in
                    // Deep link: the exact agent session, with its approval in view.
                    if let s = n.userInfo?["session"] as? String, !s.isEmpty {
                        let view = n.userInfo?["view"] as? String
                        let cloudId = n.userInfo?["machine"] as? String ?? ""
                        Task {
                            // A push from another linked machine: switch to it first.
                            if !cloudId.isEmpty, app.activeMachine?.cloudId != cloudId, let m = app.machines.first(where: { $0.cloudId == cloudId }) { await app.activate(m) }
                            app.focusApproval = view == "approval"
                            app.openAgent(s)
                            await app.refreshAgents()
                        }
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                AppLock.shared.lock()
                app.suspend()
                terminals.suspendAll()
                Notifier.shared.scheduleRefresh()
            case .active:
                if app.isPaired { app.resume() }
                terminals.resumeVisible()
            default: break
            }
        }
        .commands { WorkspaceCommands(app: app) }
    }
}

/// Physical keyboard map. App shortcuts use ⌘1–4, ⇧⌘ and ⌃⌘ so terminal and
/// remote-desktop keys (⌃C, ⌃D, Esc, Tab, arrows) always pass through.
struct WorkspaceCommands: Commands {
    let app: AppModel

    var body: some Commands {
        CommandMenu("Navigate") {
            ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { i, s in
                Button(s.title) { app.go(s) }
                    .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
            }
            Divider()
            Button("Quick Switcher…") { app.showSwitcher = true }.keyboardShortcut("k", modifiers: .command)
            Button("Quick Open File…") { app.showQuickOpen = true }.keyboardShortcut("p", modifiers: .command)
            Button("Toggle Sidebar") { withAnimation(.snappy(duration: 0.2)) { app.sidebarExpanded.toggle() } }.keyboardShortcut("0", modifiers: .command)
            Divider()
            Button("Machines & AI…") { app.sheet = .machines }.keyboardShortcut(",", modifiers: [.command, .shift])
            Button("Settings") { app.go(.settings) }.keyboardShortcut(",", modifiers: .command)
            Button("Refresh") { Task { await app.refreshAll() } }.keyboardShortcut("r", modifiers: [.command, .shift])
        }
        CommandMenu("Agent") {
            Button("New Agent Task…") {
                app.launcherProject = app.agent(app.focusedAgent)?.project ?? app.filesProject ?? app.projects.first?.id
                app.showLauncher = true
            }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Interrupt Agent") { interruptFocusedAgent() }.keyboardShortcut(".", modifiers: .command)
            Button("Git & Builds") { app.openGitBuilds(project: nil) }.keyboardShortcut("g", modifiers: [.command, .shift])
            Divider()
            Button("New Terminal") { app.showTerminal(tmux: nil) }.keyboardShortcut("t", modifiers: .command)
            Button(app.showFullScreenDesktop ? "Close Remote Desktop" : "Open Remote Desktop") { app.toggleDesktop() }
                .keyboardShortcut("d", modifiers: [.control, .command])
        }
    }

    func interruptFocusedAgent() {
        let id = app.focusedAgent ?? app.agents.first { $0.isLive && $0.status == "working" }?.id
        guard let id else { return }
        Task { _ = try? await app.client.send("POST", "/api/agents/\(id.pathSegment)/interrupt", [:], as: OK.self); await app.refreshAgents() }
    }
}
