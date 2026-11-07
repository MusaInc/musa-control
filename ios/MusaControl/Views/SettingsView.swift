import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(TerminalStore.self) private var terminals
    @State private var me: Me?
    @State private var devices: [DeviceRow] = []
    @State private var ssh = SSHSettings.stored
    @State private var sshBusy = false
    @State private var sshNote: String?
    @State private var trash: [TrashItem] = []
    @AppStorage("appearance") private var appearance = "system"
    @State private var confirmUnpair = false

    var body: some View {
        Form {
            SwiftUI.Section("Connection") {
                LabeledContent("Gateway", value: app.serverURL.absoluteString)
                LabeledContent("Status") { HStack { ConnectionDot(); Text(statusText) } }
                if let me { LabeledContent("This device", value: me.name); LabeledContent("Token expires", value: Date(timeIntervalSince1970: me.expiresAt / 1000).formatted(date: .abbreviated, time: .omitted)) }
                Button("Reconnect") { Task { await app.connect() } }
                Button("Unpair this iPad", role: .destructive) { confirmUnpair = true }
            }
            SwiftUI.Section {
                ForEach(devices) { d in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(d.name + (d.id == me?.id ? " (this iPad)" : "")).font(.system(size: 14))
                            Text("Paired \(Date(timeIntervalSince1970: d.created_at / 1000).formatted(date: .abbreviated, time: .shortened)) · last seen \(Fmt.ago(d.last_seen))").font(Theme.caption).foregroundStyle(Theme.textDim)
                        }
                        Spacer()
                        if d.revoked == 1 { Pill(text: "revoked", color: Theme.red) }
                        else if d.id != me?.id { Button("Revoke", role: .destructive) { Task { _ = try? await app.client.raw(app.client.request("DELETE", "/api/devices/\(d.id)")); await load() } } }
                    }
                }
            } header: { Text("Paired devices") } footer: { Text("Revoking a device also removes its SSH key from the server.") }

            SwiftUI.Section {
                LabeledContent("This iPad's key", value: SSHKeys.ownFingerprint).font(Theme.monoSmall)
                if let s = ssh {
                    LabeledContent("Server", value: "\(s.user)@\(s.host):\(s.port)")
                    ForEach(s.pinnedFingerprints, id: \.self) { fp in LabeledContent("Pinned host key", value: fp).font(Theme.monoSmall) }
                }
                Button { Task { await setupSSH() } } label: { HStack { if sshBusy { ProgressView().controlSize(.small) }; Text(ssh?.keyInstalled == true ? "Re-install key & refresh host keys" : "Set up SSH for this iPad") } }
                    .disabled(sshBusy)
                Button("Open a test terminal") { app.go(.terminal); terminals.newShell() }.disabled(ssh?.keyInstalled != true)
                if let sshNote { Text(sshNote).font(Theme.caption).foregroundStyle(Theme.textDim) }
            } header: { Text("SSH") } footer: {
                Text("The key is generated on this iPad and stored in the Keychain; only the public half is sent. Host keys are pinned from the gateway over TLS, and every connection is verified against them.")
            }

            SwiftUI.Section {
                Toggle("Require Face ID when returning to the app", isOn: Binding(get: { AppLock.shared.enabled }, set: { AppLock.shared.enabled = $0 }))
            } header: { Text("Security") } footer: { Text("Covers screenshots, code and agent history whenever Musa Control comes back from the background.") }

            SwiftUI.Section {
                Picker("Appearance", selection: $appearance) {
                    Text("Match iPadOS").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
                }
                Stepper("Terminal text \(Int(terminals.fontSize)) pt", value: Binding(get: { Double(terminals.fontSize) }, set: { terminals.setFontSize(CGFloat($0)) }), in: 9...24)
                Button("Reset all workspace layouts") { WorkspaceLayoutStore.resetAll() }
                Button("Clear image cache") { ImageCache.shared.clear() }
            } header: { Text("Appearance & workspace") }

            NotificationSettingsSections()

            SwiftUI.Section {
                if trash.isEmpty { Text("Empty").foregroundStyle(Theme.textDim) }
                ForEach(trash) { t in
                    HStack {
                        VStack(alignment: .leading) { Text(t.path).font(Theme.monoSmall); Text("\(app.project(t.project)?.name ?? t.project) · \(Fmt.ago(t.at))").font(Theme.caption).foregroundStyle(Theme.textDim) }
                        Spacer()
                        Button("Restore") { Task { _ = try? await app.client.send("POST", "/api/trash/\(t.id)/restore", [:], as: [String: JSONValue].self); await load() } }
                    }
                }
            } header: { Text("Trash") } footer: { Text("Files deleted from Musa Control are kept on the server and can be restored.") }

            SwiftUI.Section("About") {
                LabeledContent("Version", value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
                Text("Musa Control runs nothing on the iPad itself: agents, builds, tmux and the desktop all live on the server.").font(Theme.caption).foregroundStyle(Theme.textDim)
            }
        }
        .scrollContentBackground(.hidden).background(Theme.bg)
        .task { await load() }
        .confirmationDialog("Unpair this iPad?", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) {
                Task { if let id = me?.id { _ = try? await app.client.raw(app.client.request("DELETE", "/api/devices/\(id)")) }; app.unpair() }
            }
        } message: { Text("Revokes this iPad's token and SSH key on the server. Running agents and sessions are not affected.") }
    }

    var statusText: String {
        switch app.phase { case .ready: return app.streamState == .live ? "Live" : "Connected (event stream reconnecting)"; case .connecting: return "Connecting"; case .offline(let m): return "Offline — \(m)"; case .unpaired: return "Not paired" }
    }

    func load() async {
        me = try? await app.client.get("/api/me", as: Me.self)
        devices = (try? await app.client.get("/api/devices", as: [DeviceRow].self)) ?? []
        trash = (try? await app.client.get("/api/trash", as: [TrashItem].self)) ?? []
    }

    func setupSSH() async {
        sshBusy = true; defer { sshBusy = false }
        do {
            let keys = try await app.client.send("POST", "/api/ssh/authorize", ["publicKey": SSHKeys.openSSHPublicKey(comment: "musa-control")], as: HostKeys.self)
            let s = SSHSettings(host: keys.host, port: keys.port, user: keys.user, pinnedFingerprints: keys.keys.map(\.fingerprint), keyInstalled: true)
            SSHSettings.stored = s; ssh = s
            sshNote = "Key installed for \(keys.user)@\(keys.host). \(keys.keys.count) host keys pinned."
        } catch { sshNote = error.localizedDescription }
    }
}

/// Push notification settings. Preferences are stored on the gateway so they
/// apply while the app is closed; changes sync immediately.
struct NotificationSettingsSections: View {
    @Environment(AppModel.self) private var app
    @State private var permission: UNAuthorizationStatus = .notDetermined
    @State private var status: PushStatus?
    @State private var prefs = Notifier.shared.prefs
    @State private var note: String?
    @State private var busy = false

    var body: some View {
        SwiftUI.Section {
            LabeledContent("Permission") { Text(permissionText).foregroundStyle(permission == .denied ? Theme.red : Theme.textDim) }
            LabeledContent("Delivery") {
                HStack(spacing: 6) { StatusDot(status: deliveryDot, size: 7); Text(deliveryText).multilineTextAlignment(.trailing) }.foregroundStyle(Theme.textDim)
            }
            if let e = status?.lastError { LabeledContent("Last push error", value: e).foregroundStyle(Theme.red) }
            if permission != .authorized && permission != .denied {
                Button("Allow notifications") { Task { _ = await Notifier.shared.requestPermission(); try? await Task.sleep(nanoseconds: 1_200_000_000); await refresh() } }
            }
            if permission == .denied {
                Button("Open iPadOS Settings") { if let u = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(u) } }
            }
            Button { Task { busy = true; defer { busy = false }; do { _ = try await app.client.send("POST", "/api/push/test", [:], as: OK.self); note = "Test sent. It should arrive within a few seconds — try it with the iPad locked." } catch { note = error.localizedDescription } } } label: {
                HStack { if busy { ProgressView().controlSize(.small) }; Text("Send a test notification") }
            }
            .disabled(status?.registered != true || busy)
            if let note { Text(note).font(Theme.caption).foregroundStyle(Theme.textDim) }
        } header: { Text("Notifications") } footer: {
            Text("Approval requests can be approved or rejected straight from the notification after Face ID or your passcode. Risky commands, folder-trust prompts and commands whose details are hidden on the agent's screen always open the app instead. Each approval works once, only while it is still pending, and expires after 15 minutes.")
        }

        SwiftUI.Section {
            ForEach(Notifier.Category.allCases, id: \.self) { c in
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: bind(\.categories, c.rawValue, true)) {
                        VStack(alignment: .leading, spacing: 2) { Text(c.title); Text(c.detail).font(Theme.caption).foregroundStyle(Theme.textDim) }
                    }
                    if prefs.on(c) {
                        Toggle("Sound", isOn: bind(\.sounds, c.rawValue, c == .approvals)).font(Theme.caption).foregroundStyle(Theme.textDim).padding(.leading, 18)
                    }
                }
            }
        } header: { Text("What notifies you") }

        SwiftUI.Section {
            Toggle("Claude Code", isOn: agentBinding("claude"))
            Toggle("Codex", isOn: agentBinding("codex"))
            DisclosureGroup("Projects (\(app.projects.count - prefs.mutedProjects.filter { id in app.projects.contains { $0.id == id } }.count) of \(app.projects.count) on)") {
                ForEach(app.projects) { p in
                    Toggle(isOn: projectBinding(p.id)) { Label(p.name, systemImage: p.icon) }
                }
            }
        } header: { Text("From") } footer: { Text("Muted projects and agents still show everything inside the app.") }
        .task { await refresh() }
    }

    var permissionText: String {
        switch permission { case .authorized, .provisional, .ephemeral: return "Allowed"; case .denied: return "Off in iPadOS Settings"; default: return "Not asked yet" }
    }
    var deliveryDot: String { status?.serverConfigured == true && status?.registered == true ? "idle" : status?.serverConfigured == false ? "approval" : "other" }
    var deliveryText: String {
        guard let s = status else { return "Checking…" }
        if !s.serverConfigured { return "Push not set up on the server yet — notifications arrive while the app is open and on background refreshes" }
        if !s.registered { return permission == .authorized ? "Registering this iPad…" : "Allow notifications to receive push" }
        return "Instant push (\(s.environment == "sandbox" ? "development" : "production") APNs)"
    }

    func bind(_ kp: WritableKeyPath<Notifier.Prefs, [String: Bool]>, _ key: String, _ def: Bool) -> Binding<Bool> {
        Binding(get: { prefs[keyPath: kp][key] ?? def }, set: { prefs[keyPath: kp][key] = $0; save() })
    }
    func agentBinding(_ a: String) -> Binding<Bool> {
        Binding(get: { !prefs.mutedAgents.contains(a) }, set: { on in prefs.mutedAgents.removeAll { $0 == a }; if !on { prefs.mutedAgents.append(a) }; save() })
    }
    func projectBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { !prefs.mutedProjects.contains(id) }, set: { on in prefs.mutedProjects.removeAll { $0 == id }; if !on { prefs.mutedProjects.append(id) }; save() })
    }

    func save() {
        Notifier.shared.prefs = prefs
        Task { if let s = await Notifier.shared.pushPrefs() { status = s } }
    }

    func refresh() async {
        permission = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if permission == .authorized { _ = await Notifier.shared.syncRegistration() }
        status = try? await app.client.get("/api/push", as: PushStatus.self)
        if let p = status?.prefs, status?.registered == true { prefs = p; Notifier.shared.prefs = p }
        Notifier.shared.pushActive = status?.serverConfigured == true && status?.registered == true
    }
}
