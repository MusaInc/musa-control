import Foundation
import UIKit
import UserNotifications
import BackgroundTasks

/// Notifications for approvals, agents waiting for input, finished or failed
/// work, builds and server alerts.
///
/// * Primary path: APNs push sent by the gateway (works when the app is
///   closed, suspended or the iPad is locked). Filtering by category, project
///   and agent happens on the server, from preferences this app syncs.
/// * Approval pushes offer Approve / Reject. Both require the device to be
///   unlocked (Face ID / passcode); the gateway accepts each action token once,
///   for this device, only while the same prompt is still on screen. Risky or
///   partly hidden commands arrive without buttons and open the app.
/// * Fallback when push isn't available (no APNs key on the server yet, or
///   permission denied): local notifications from the live stream while the
///   app runs, and periodic background refreshes.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    static let refreshId = "uk.co.musastudios.musacontrol.refresh"

    enum Category: String, CaseIterable, Codable { case approvals, input, completed, failed, builds, server
        var title: String {
            switch self {
            case .approvals: return "Approval requests"; case .input: return "Agent waiting for your answer"; case .completed: return "Finished tasks"
            case .failed: return "Errors"; case .builds: return "Builds & CI"; case .server: return "Server alerts"
            }
        }
        var detail: String {
            switch self {
            case .approvals: return "Codex or Claude Code needs permission to continue."
            case .input: return "A turn ended with a question for you."
            case .completed: return "A task or long turn finished."
            case .failed: return "Real agent errors (routine failed commands never notify)."
            case .builds: return "Project builds and GitHub Actions runs."
            case .server: return "Services down, disk nearly full."
            }
        }
    }

    // MARK: Preferences (mirrored on the gateway)

    struct Prefs: Codable, Equatable {
        var categories: [String: Bool] = Dictionary(uniqueKeysWithValues: Category.allCases.map { ($0.rawValue, true) })
        var sounds: [String: Bool] = ["approvals": true, "input": true, "completed": false, "failed": true, "builds": false, "server": true]
        var mutedProjects: [String] = []
        var mutedAgents: [String] = []
        func on(_ c: Category) -> Bool { categories[c.rawValue] ?? true }
        func sound(_ c: Category) -> Bool { sounds[c.rawValue] ?? (c == .approvals) }
    }

    var prefs: Prefs {
        get { (UserDefaults.standard.data(forKey: "notify.prefs")).flatMap { try? JSONDecoder().decode(Prefs.self, from: $0) } ?? Prefs() }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "notify.prefs") }
    }
    /// True once the gateway confirmed it can push to this device; local
    /// fallback notifications are then suppressed so nothing arrives twice.
    var pushActive: Bool {
        get { UserDefaults.standard.bool(forKey: "notify.pushActive") }
        set { UserDefaults.standard.set(newValue, forKey: "notify.pushActive") }
    }

    func category(for ev: TimelineEvent) -> Category? {
        switch ev.kind {
        case "agent.approval": return .approvals
        case "agent.done":
            let last = (ev.detail?["last"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return last.hasSuffix("?") ? .input : .completed
        case "agent.error": return .failed
        case "build.finished", "ci.finished": return .builds
        case "server.alert": return .server
        default: return nil
        }
    }

    // MARK: Setup

    static let approveAction = "MC_APPROVE"
    static let rejectAction = "MC_REJECT"
    static let openAction = "MC_OPEN"

    func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let approve = UNNotificationAction(identifier: Self.approveAction, title: "Approve", options: [.authenticationRequired], icon: UNNotificationActionIcon(systemImageName: "checkmark.circle"))
        let reject = UNNotificationAction(identifier: Self.rejectAction, title: "Reject", options: [.authenticationRequired, .destructive], icon: UNNotificationActionIcon(systemImageName: "xmark.circle"))
        let open = UNNotificationAction(identifier: Self.openAction, title: "Review in Musa Control", options: [.foreground], icon: UNNotificationActionIcon(systemImageName: "arrow.up.forward.app"))
        let cats: Set<UNNotificationCategory> = [
            UNNotificationCategory(identifier: "MC_APPROVAL", actions: [approve, reject, open], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: "An agent needs approval", options: []),
            UNNotificationCategory(identifier: "MC_APPROVAL_REVIEW", actions: [open], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: "An agent needs approval", options: []),
        ]
        center.setNotificationCategories(cats)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshId, using: nil) { task in
            self.handleRefresh(task as! BGAppRefreshTask)
        }
    }

    func requestPermission() async -> Bool {
        let ok = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        if ok { await MainActor.run { UIApplication.shared.registerForRemoteNotifications() } }
        return ok
    }

    /// Re-register on every launch: tokens change after restores/reinstalls.
    func registerIfAllowed() async {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        guard s.authorizationStatus == .authorized || s.authorizationStatus == .provisional else { return }
        await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
    }

    // MARK: APNs registration

    func didRegister(deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(hex, forKey: "notify.apnsToken")
        Task { await syncRegistration() }
    }

    func didFailToRegister(_ error: Error) {
        UserDefaults.standard.set(error.localizedDescription, forKey: "notify.registerError")
        pushActive = false
    }

    /// Sends the token and preferences to the gateway; returns its status.
    @discardableResult
    func syncRegistration() async -> PushStatus? {
        guard let client = Self.backgroundClient(), let token = UserDefaults.standard.string(forKey: "notify.apnsToken") else { return nil }
        let prefsData: Any = (try? JSONEncoder().encode(prefs)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? [String: Any]()
        let s = try? await client.send("POST", "/api/push/register", ["token": token, "environment": Self.apnsEnvironment, "prefs": prefsData], as: PushStatus.self)
        if let s { pushActive = s.serverConfigured && s.registered }
        return s
    }

    func pushPrefs() async -> PushStatus? {
        guard let client = Self.backgroundClient() else { return nil }
        let body = (try? JSONEncoder().encode(prefs)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let s = try? await client.send("PUT", "/api/push/prefs", body, as: PushStatus.self)
        if let s { pushActive = s.serverConfigured && s.registered }
        return s
    }

    /// Development-signed builds talk to the APNs sandbox; TestFlight and App
    /// Store builds (no embedded provisioning profile, or a production one)
    /// to production.
    static var apnsEnvironment: String {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .isoLatin1) else { return "production" }
        if let r = text.range(of: "<key>aps-environment</key>") {
            let tail = text[r.upperBound...].prefix(80)
            if tail.contains("development") { return "sandbox" }
        }
        return "production"
    }

    static func backgroundClient() -> GatewayClient? {
        guard let token = Keychain.string("deviceToken"), let base = URL(string: UserDefaults.standard.string(forKey: "serverURL") ?? "") else { return nil }
        return GatewayClient(base: base, token: token)
    }

    // MARK: Local fallback

    func deliver(_ ev: TimelineEvent, foreground: Bool) {
        guard !pushActive, let cat = category(for: ev) else { return }
        let p = prefs
        guard p.on(cat) else { return }
        if let proj = ev.project, p.mutedProjects.contains(proj) { return }
        if let a = ev.detail?["agent"]?.string, p.mutedAgents.contains(a) { return }
        if foreground && cat != .approvals { return } // the in-app banner covers it
        let c = UNMutableNotificationContent()
        c.title = {
            switch cat { case .approvals: return "Approval needed"; case .input: return "Waiting for you"; case .failed: return "Something failed"; case .builds: return "Build finished"; case .server: return "Server alert"; case .completed: return "Task finished" }
        }()
        c.body = ev.title
        c.sound = p.sound(cat) ? .default : nil
        c.threadIdentifier = ev.session ?? ev.project ?? cat.rawValue
        c.categoryIdentifier = cat == .approvals ? "MC_APPROVAL_REVIEW" : ""
        c.userInfo = ["mc": ["session": ev.session ?? "", "project": ev.project ?? "", "kind": ev.kind, "view": cat == .approvals ? "approval" : "activity"]]
        let id = "mc-\(ev.id.map(String.init) ?? UUID().uuidString)"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    func scheduleRefresh() {
        guard !pushActive else { return }
        let r = BGAppRefreshTaskRequest(identifier: Self.refreshId)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }

    private func handleRefresh(_ task: BGAppRefreshTask) {
        scheduleRefresh()
        let work = Task {
            defer { task.setTaskCompleted(success: true) }
            guard !pushActive, let client = Self.backgroundClient() else { return }
            let after = UserDefaults.standard.string(forKey: "lastNotifiedId") ?? UserDefaults.standard.string(forKey: "lastEventId") ?? "0"
            guard let evs = try? await client.get("/api/notifications", ["after": after], as: [TimelineEvent].self) else { return }
            for ev in evs { deliver(ev, foreground: false) }
            if let last = evs.last?.id { UserDefaults.standard.set(String(last), forKey: "lastNotifiedId") }
        }
        task.expirationHandler = { work.cancel() }
    }

    // MARK: Silent pushes

    /// The gateway sends a silent push when an approval was answered elsewhere
    /// or vanished, so the stale notification (and its buttons) disappears.
    func handleRemote(_ info: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard let mc = info["mc"] as? [String: Any], let withdraw = mc["withdraw"] as? String else { return .noData }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [withdraw])
        return .newData
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let cat = notification.request.content.categoryIdentifier
        // Approvals always show (with their buttons); other pushes go to the
        // list only, because the in-app banner already shows them.
        if cat.hasPrefix("MC_APPROVAL") || cat == "MC_TEST" { return [.banner, .list, .sound] }
        return [.list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        let mc = content.userInfo["mc"] as? [String: Any] ?? [:]
        let session = mc["session"] as? String ?? content.userInfo["session"] as? String ?? ""
        switch response.actionIdentifier {
        case Self.approveAction, Self.rejectAction:
            await act(approve: response.actionIdentifier == Self.approveAction, mc: mc, title: content.title)
        default:
            await MainActor.run {
                NotificationCenter.default.post(name: .openFromNotification, object: nil, userInfo: ["session": session, "view": mc["view"] as? String ?? "activity"])
            }
        }
    }

    /// Approve/Reject without opening the app. The result (or why it didn't
    /// go through) is confirmed with a quiet follow-up notification.
    private func act(approve: Bool, mc: [String: Any], title: String) async {
        let report: (String, String) -> Void = { t, b in
            let c = UNMutableNotificationContent(); c.title = t; c.body = b; c.threadIdentifier = mc["session"] as? String ?? ""
            c.userInfo = ["mc": ["session": mc["session"] as? String ?? "", "view": "activity"]]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "mc-result-\(UUID().uuidString)", content: c, trigger: nil))
        }
        guard let nonce = mc["nonce"] as? String, let client = Self.backgroundClient() else {
            report("Couldn't answer", "Open Musa Control to review this request."); return
        }
        let bg = await MainActor.run { UIApplication.shared.beginBackgroundTask(withName: "approval") }
        defer { Task { @MainActor in UIApplication.shared.endBackgroundTask(bg) } }
        do {
            let r = try await client.send("POST", "/api/push/action", ["nonce": nonce, "action": approve ? "approve" : "reject"], as: PushActionResult.self, timeout: 20)
            report(approve ? "Approved" : "Rejected", "\(r.answered ?? (approve ? "Approved" : "Rejected")) — \(title.replacingOccurrences(of: " needs approval", with: ""))")
        } catch {
            report("Not sent", "\(error.localizedDescription) Open Musa Control to check the agent.")
        }
    }
}

struct PushStatus: Codable, Equatable {
    let serverConfigured: Bool
    let reason: String?
    let registered: Bool
    let environment: String?
    let lastSent: Double?
    let lastError: String?
    let prefs: Notifier.Prefs?
}

struct PushActionResult: Codable { let ok: Bool; let answered: String?; let action: String? }

extension Notification.Name { static let openFromNotification = Notification.Name("mc.openFromNotification") }
