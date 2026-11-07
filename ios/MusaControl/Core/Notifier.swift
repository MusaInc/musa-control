import Foundation
import UserNotifications
import BackgroundTasks

/// Notifications for approvals, finished/failed work, builds and server
/// alerts. While the app runs they come from the live event stream; when it's
/// suspended iOS wakes it periodically (BGAppRefreshTask, timing chosen by
/// the system) to poll /api/notifications. Remote work never depends on the
/// app being alive: agents, builds and tmux run on the server.
///
/// Instant push while the app is closed needs an APNs key on the server,
/// which isn't configured yet (see docs/LIMITATIONS.md).
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    static let refreshId = "uk.co.musastudios.musacontrol.refresh"

    enum Category: String, CaseIterable { case approvals, completed, failed, builds, server
        var title: String { switch self { case .approvals: return "Agent approvals"; case .completed: return "Completed tasks"; case .failed: return "Failures"; case .builds: return "Builds & CI"; case .server: return "Server issues" } }
    }

    func enabled(_ c: Category) -> Bool { UserDefaults.standard.object(forKey: "notify.\(c.rawValue)") as? Bool ?? true }
    func setEnabled(_ c: Category, _ on: Bool) { UserDefaults.standard.set(on, forKey: "notify.\(c.rawValue)") }

    func category(for ev: TimelineEvent) -> Category {
        switch ev.kind {
        case "agent.approval": return .approvals
        case "agent.error", "agent.command_failed": return .failed
        case "build.finished", "ci.finished": return .builds
        case "server.alert": return .server
        default: return .completed
        }
    }

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func setup() {
        UNUserNotificationCenter.current().delegate = self
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshId, using: nil) { task in
            self.handleRefresh(task as! BGAppRefreshTask)
        }
    }

    func deliver(_ ev: TimelineEvent, foreground: Bool) {
        let cat = category(for: ev)
        guard enabled(cat) else { return }
        if foreground && cat != .approvals { return } // in-app banner covers it
        let c = UNMutableNotificationContent()
        c.title = {
            switch cat { case .approvals: return "Approval needed"; case .failed: return "Something failed"; case .builds: return "Build finished"; case .server: return "Server alert"; case .completed: return "Task finished" }
        }()
        c.body = ev.title
        c.sound = cat == .approvals || cat == .failed ? .default : nil
        c.threadIdentifier = ev.session ?? ev.project ?? cat.rawValue
        c.userInfo = ["session": ev.session ?? "", "project": ev.project ?? "", "kind": ev.kind]
        let id = "mc-\(ev.id.map(String.init) ?? UUID().uuidString)"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    func scheduleRefresh() {
        let r = BGAppRefreshTaskRequest(identifier: Self.refreshId)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }

    private func handleRefresh(_ task: BGAppRefreshTask) {
        scheduleRefresh()
        let work = Task {
            defer { task.setTaskCompleted(success: true) }
            guard let token = Keychain.string("deviceToken"),
                  let base = URL(string: UserDefaults.standard.string(forKey: "serverURL") ?? "") else { return }
            let client = GatewayClient(base: base, token: token)
            let after = UserDefaults.standard.string(forKey: "lastNotifiedId") ?? UserDefaults.standard.string(forKey: "lastEventId") ?? "0"
            guard let evs = try? await client.get("/api/notifications", ["after": after], as: [TimelineEvent].self) else { return }
            for ev in evs { deliver(ev, foreground: false) }
            if let last = evs.last?.id { UserDefaults.standard.set(String(last), forKey: "lastNotifiedId") }
        }
        task.expirationHandler = { work.cancel() }
    }

    // Show approvals even in the foreground.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let session = info["session"] as? String ?? ""
        await MainActor.run {
            NotificationCenter.default.post(name: .openFromNotification, object: nil, userInfo: ["session": session])
        }
    }
}

extension Notification.Name { static let openFromNotification = Notification.Name("mc.openFromNotification") }
