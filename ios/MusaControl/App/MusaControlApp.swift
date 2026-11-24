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

/// Keyboard map. Musa Control's own shortcuts use ⌘ with digits/symbols,
/// ⇧⌘ or ⌃⌘, so the keys a terminal or remote session needs (⌃C, ⌃D, Esc,
/// Tab, arrows, F-keys, and ⌘C/⌘V/⌘Z/⌘S/⌘F while the desktop has the
/// keyboard) always reach it. Hold ⌘ to see this list.
struct WorkspaceCommands: Commands {
    let app: AppModel

    var body: some Commands {
        CommandMenu("Workspace") {
            Button("Quick Open…") { app.showQuickOpen = true }.keyboardShortcut("p", modifiers: .command)
            Button("Go to Project, Agent or Panel…") { app.showSwitcher = true }.keyboardShortcut("k", modifiers: .command)
            Button("Find in Project…") { app.workspace.navigator = .files; app.workspace.navigatorVisible = true }.keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            Button(app.workspace.navigatorVisible ? "Hide Navigator" : "Show Navigator") { withAnimation(.snappy(duration: 0.2)) { app.workspace.navigatorVisible.toggle() } }.keyboardShortcut("0", modifiers: .command)
            Button("Files") { app.workspace.navigator = .files; app.workspace.navigatorVisible = true }.keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Agents") { app.workspace.navigator = .agents; app.workspace.navigatorVisible = true }.keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Source Control") { app.workspace.navigator = .git; app.workspace.navigatorVisible = true }.keyboardShortcut("g", modifiers: [.command, .shift])
            Divider()
            ForEach(Array(WorkspaceLayout.Preset.allCases.enumerated()), id: \.element) { i, p in
                Button("\(p.title) Layout") { withAnimation(.snappy(duration: 0.25)) { app.workspace.apply(p) } }
                    .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: [.control, .command])
            }
            Divider()
            Button("Machines & AI…") { app.sheet = .machines }.keyboardShortcut(",", modifiers: [.command, .shift])
            Button("Settings…") { app.sheet = .settings }.keyboardShortcut(",", modifiers: .command)
            Button("Refresh") { Task { await app.refreshAll() } }.keyboardShortcut("r", modifiers: [.command, .shift])
        }
        CommandMenu("Panels") {
            ForEach(1...9, id: \.self) { n in
                Button("Focus Panel \(n)") { app.workspace.focus(index: n - 1) }.keyboardShortcut(KeyEquivalent(Character(String(n))), modifiers: .command)
            }
            Button("Next Panel") { app.workspace.cycleFocus(1) }.keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Previous Panel") { app.workspace.cycleFocus(-1) }.keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Divider()
            ForEach(PanelKind.allCases) { k in
                Button("Show \(k.title)") { app.workspace.reveal(k) }.keyboardShortcut(KeyEquivalent(k.key), modifiers: [.control, .command])
            }
            Divider()
            Button("New Terminal") { app.showTerminal(tmux: nil) }.keyboardShortcut("t", modifiers: .command)
            Button("Split: Terminal Below") { _ = app.workspace.add(.terminal, beside: app.workspace.focused) }.keyboardShortcut("d", modifiers: .command)
            Button("Maximise / Restore Panel") { if let f = app.workspace.focused { withAnimation(.snappy(duration: 0.2)) { app.workspace.toggleMaximize(f) } } }.keyboardShortcut("m", modifiers: [.control, .command])
            Button("Close Panel") { if let f = app.workspace.focused { withAnimation(.snappy(duration: 0.2)) { app.workspace.close(f) } } }.keyboardShortcut("w", modifiers: [.control, .command])
        }
        CommandMenu("Agent") {
            Button("New Agent Task…") { app.launcherProject = app.workspace.projectId; app.showLauncher = true }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Show Agent Activity") { app.workspace.reveal(.agent) }.keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Interrupt Agent") { interruptFocusedAgent() }.keyboardShortcut(".", modifiers: .command)
        }
        CommandMenu("Remote Desktop") {
            Button(app.desktop.active ? "Close Remote Desktop" : "Open Remote Desktop") { withAnimation(.snappy(duration: 0.25)) { app.toggleDesktop() } }.keyboardShortcut("d", modifiers: [.control, .command])
            Button("Beside the Workspace") { show(.split) }.keyboardShortcut("\\", modifiers: [.control, .command])
            Button("Floating Window") { show(.floating) }.keyboardShortcut("p", modifiers: [.control, .command])
            Button("Full Screen") { show(app.desktop.presentation == .full ? .split : .full) }.keyboardShortcut("f", modifiers: [.control, .command])
            Button("Minimise to Thumbnail") { show(.mini) }.keyboardShortcut("j", modifiers: [.control, .command])
            Divider()
            Button(app.desktop.control ? "Watch Only" : "Take Control") { app.desktop.setControl(!app.desktop.control); if app.desktop.control { app.desktop.focusKeyboard() } }
                .keyboardShortcut("c", modifiers: [.control, .command]).disabled(!app.desktop.active)
            Button("Give Keyboard to Desktop") { app.desktop.focusKeyboard() }.keyboardShortcut("k", modifiers: [.control, .command]).disabled(!app.desktop.active)
            Button("Paste iPad Clipboard into Desktop") { app.desktop.pasteFromDevice() }.keyboardShortcut("v", modifiers: [.control, .command]).disabled(!app.desktop.control)
            Button("Reconnect") { app.desktop.reconnect() }.keyboardShortcut("r", modifiers: [.control, .command]).disabled(!app.desktop.active)
        }
    }

    func show(_ p: DesktopStore.Presentation) {
        withAnimation(.snappy(duration: 0.25)) {
            if !app.desktop.active { app.showDesktop(follow: false) }
            app.desktop.presentation = p
        }
    }

    func interruptFocusedAgent() {
        let ws = app.workspace
        let slot = ws.layout.slots.first { $0.id == ws.focused && $0.kind == .agent } ?? ws.layout.slots.first { $0.kind == .agent }
        let id = slot?.config["agent"] ?? app.agents.first { $0.isLive && $0.project == ws.projectId && $0.status == "working" }?.id
        guard let id else { return }
        Task { _ = try? await app.client.send("POST", "/api/agents/\(id.pathSegment)/interrupt", [:], as: OK.self); await app.refreshAgents() }
    }
}
