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
    @State private var notifyStatus = "Unknown"
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
                            Text(d.name + (d.id == me?.id ? " (this iPad)" : "")).font(.system(size: 13))
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
                Stepper("Terminal text \(Int(terminals.fontSize)) pt", value: Binding(get: { Double(terminals.fontSize) }, set: { terminals.setFontSize(CGFloat($0)) }), in: 9...24)
                Button("Reset all workspace layouts") { WorkspaceLayoutStore.resetAll() }
                Button("Clear image cache") { ImageCache.shared.clear() }
            } header: { Text("Appearance & workspace") }

            SwiftUI.Section {
                LabeledContent("Permission", value: notifyStatus)
                if notifyStatus != "Allowed" { Button("Allow notifications") { Notifier.shared.requestPermission(); Task { try? await Task.sleep(nanoseconds: 800_000_000); await refreshNotify() } } }
                ForEach(Notifier.Category.allCases, id: \.self) { c in
                    Toggle(c.title, isOn: Binding(get: { Notifier.shared.enabled(c) }, set: { Notifier.shared.setEnabled(c, $0) }))
                }
            } header: { Text("Notifications") } footer: {
                Text("Delivered live while Musa Control is open, and from periodic background refreshes (timing is up to iOS). Instant push while the app is closed needs an APNs key on the server, which isn't set up yet. Your work never depends on the app staying open: it all runs on the server.")
            }

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
        .task { await load(); await refreshNotify() }
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

    func refreshNotify() async {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        notifyStatus = s.authorizationStatus == .authorized ? "Allowed" : s.authorizationStatus == .denied ? "Denied (change in iPadOS Settings)" : "Not asked yet"
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
