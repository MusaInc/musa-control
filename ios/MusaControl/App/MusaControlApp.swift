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
                .environment(terminals)
                .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
                .tint(Theme.accent)
                .task { if app.isPaired { await app.connect() } }
                .onReceive(NotificationCenter.default.publisher(for: .openFromNotification)) { n in
                    // Deep link: the exact agent session, with its approval in view.
                    if let s = n.userInfo?["session"] as? String, !s.isEmpty {
                        app.focusApproval = (n.userInfo?["view"] as? String) == "approval"
                        app.openAgent(s)
                        Task { await app.refreshAgents() }
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
        .commands {
            CommandMenu("Navigate") {
                ForEach(AppSection.allCases) { s in
                    Button(s.title) { app.go(s) }.keyboardShortcut(s.shortcut, modifiers: .command)
                }
                Divider()
                Button(app.sidebarExpanded ? "Collapse Sidebar" : "Show Sidebar") { withAnimation(.snappy(duration: 0.22)) { app.sidebarExpanded.toggle(); app.sidebarOverlay.toggle() } }.keyboardShortcut("s", modifiers: [.control, .command])
                Button("Quick Switch…") { app.showSwitcher = true }.keyboardShortcut("k", modifiers: .command)
                Button("New Agent Task…") { app.launcherProject = app.workspaceProject; app.showLauncher = true }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button(app.followPaused ? "Resume Follow Agent" : "Pause Follow Agent") { app.followPaused.toggle() }.keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Refresh") { Task { await app.refreshAll() } }.keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandMenu("Terminal") {
                Button("New Terminal Tab") { app.go(.terminal); terminals.newShell() }.keyboardShortcut("t", modifiers: .command)
                Button("Split Terminal") {
                    app.go(.terminal)
                    if terminals.splitWith == nil, let other = terminals.sessions.first(where: { $0.id != terminals.selected }) { terminals.splitWith = other.id } else { terminals.splitWith = nil }
                }.keyboardShortcut("d", modifiers: .command)
                Button("Next Tab") {
                    guard let i = terminals.sessions.firstIndex(where: { $0.id == terminals.selected }), !terminals.sessions.isEmpty else { return }
                    terminals.selected = terminals.sessions[(i + 1) % terminals.sessions.count].id
                }.keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Tab") {
                    guard let i = terminals.sessions.firstIndex(where: { $0.id == terminals.selected }), !terminals.sessions.isEmpty else { return }
                    terminals.selected = terminals.sessions[(i - 1 + terminals.sessions.count) % terminals.sessions.count].id
                }.keyboardShortcut("[", modifiers: [.command, .shift])
            }
        }
    }
}
