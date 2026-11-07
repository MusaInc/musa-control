import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Notifier.shared.setup()
        return true
    }
}

@main
struct MusaControlApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var app = AppModel()
    @State private var terminals = TerminalStore.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .overlay { LockOverlay() }
                .environment(app)
                .environment(terminals)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .task { if app.isPaired { await app.connect() } }
                .onReceive(NotificationCenter.default.publisher(for: .openFromNotification)) { n in
                    if let s = n.userInfo?["session"] as? String, !s.isEmpty { app.openAgent(s) }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                AppLock.shared.lock()
                app.suspend()
                Notifier.shared.scheduleRefresh()
            case .active:
                if app.isPaired { app.resume() }
                terminals.sessions.forEach { if $0.state != .closed { $0.open() } }
            default: break
            }
        }
        .commands {
            CommandMenu("Navigate") {
                ForEach(AppSection.allCases) { s in
                    Button(s.title) { app.go(s) }.keyboardShortcut(s.shortcut, modifiers: .command)
                }
                Divider()
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
