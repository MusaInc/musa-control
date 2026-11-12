import SwiftUI

/// The Musa Control account: who's signed in, where, the security log,
/// export and deletion (required for any app with sign-up).
struct AccountView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var account = Account.shared
    @State private var sessions: [CloudSession] = []
    @State private var audit: [AuditEntry] = []
    @State private var name = ""
    @State private var exportURL: URL?
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var deleteText = ""
    @State private var deletePassword = ""
    @State private var deleting = false

    var body: some View {
        NavigationStack {
            Form {
                SwiftUI.Section("Profile") {
                    TextField("Name", text: $name).onSubmit { Task { try? await account.rename(name) } }
                    LabeledContent("Email", value: account.user?.email ?? "Hidden (Sign in with Apple)")
                    LabeledContent("Sign-in", value: (account.user?.methods ?? []).map { $0 == "apple" ? "Apple" : "Password" }.joined(separator: ", "))
                }
                SwiftUI.Section {
                    ForEach(sessions) { s in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text((s.deviceName ?? "Device") + (s.current ? " (this \(Device.name))" : "")).font(.system(size: 14))
                                Text("\(s.platform ?? "") · last active \(Fmt.ago(s.lastSeen))").font(Theme.caption).foregroundStyle(Theme.textDim)
                            }
                            Spacer()
                            if !s.current { Button("Sign out", role: .destructive) { Task { try? await account.revoke(s.id); await load() } } }
                        }
                    }
                    if sessions.count > 1 { Button("Sign out everywhere else", role: .destructive) { Task { try? await account.revokeOthers(); await load() } } }
                } header: { Text("Signed-in devices") } footer: { Text("Signing a device out also cuts its access to your linked computers at once.") }
                SwiftUI.Section {
                    ForEach(audit.prefix(60)) { e in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.describe(e)).font(.system(size: 13.5))
                            Text("\(Date(timeIntervalSince1970: e.ts / 1000).formatted(date: .abbreviated, time: .shortened))\(e.ip.map { " · \($0)" } ?? "")").font(Theme.caption).foregroundStyle(Theme.textFaint)
                        }
                    }
                } header: { Text("Security log") }
                SwiftUI.Section {
                    Button("Export my data") { Task { await export() } }
                    if let exportURL { ShareLink(item: exportURL) { Label("Share export", systemImage: "square.and.arrow.up") } }
                    Button("Sign out of this \(Device.name)") { Task { await account.signOut(); app.reloadMachines(); dismiss() } }
                    Button("Delete account…", role: .destructive) { confirmDelete = true }.accessibilityIdentifier("account.delete")
                } footer: {
                    Text("Deleting the account removes it, its sessions, linked computers and security log from Musa Control's service. Nothing on your computers is deleted; unlinked companions simply stop connecting.")
                }
                if let error { Text(error).foregroundStyle(Theme.red).font(Theme.caption) }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { name = account.user?.name ?? ""; await load() }
            .sheet(isPresented: $confirmDelete) { deleteSheet }
        }
    }

    var deleteSheet: some View {
        NavigationStack {
            Form {
                SwiftUI.Section {
                    Text("This permanently deletes your Musa Control account and unlinks every computer linked to it. It can't be undone.").fixedSize(horizontal: false, vertical: true)
                    TextField("Type DELETE", text: $deleteText).textInputAutocapitalization(.characters).autocorrectionDisabled().accessibilityIdentifier("account.delete.confirm")
                    if account.user?.methods.contains("password") == true && account.user?.methods.contains("apple") != true {
                        SecureField("Password", text: $deletePassword)
                    }
                }
                if let error { Text(error).foregroundStyle(Theme.red).font(Theme.caption) }
                Button(role: .destructive) { Task { await delete() } } label: { HStack { if deleting { ProgressView().controlSize(.small) }; Text("Delete my account") } }
                    .disabled(deleteText != "DELETE" || deleting)
            }
            .navigationTitle("Delete account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { confirmDelete = false } } }
        }
    }

    func load() async {
        do { sessions = try await account.sessions(); audit = try await account.audit(); error = nil }
        catch { self.error = error.localizedDescription }
    }

    func export() async {
        do {
            let d = try await account.exportData()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("musa-control-account.json")
            try d.write(to: url, options: .completeFileProtection)
            exportURL = url
        } catch { self.error = error.localizedDescription }
    }

    func delete() async {
        deleting = true; defer { deleting = false }
        do {
            try await account.deleteAccount(password: deletePassword)
            confirmDelete = false
            app.reloadMachines()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    static func describe(_ e: AuditEntry) -> String {
        let d = e.detail
        switch e.action {
        case "session.created": return "Signed in on \(d?["device"]?.string ?? "a device") (\(d?["method"]?.string ?? ""))"
        case "session.revoked": return "Signed a device out"
        case "session.revoked_all": return "Signed out everywhere else"
        case "login.failed": return "Failed sign-in attempt"
        case "account.created": return "Account created"
        case "account.password_changed": return "Password changed"
        case "account.apple_linked": return "Sign in with Apple added"
        case "machine.code_created": return "Link code created"
        case "machine.linked": return "Linked \(d?["hostname"]?.string ?? "a computer")"
        case "machine.removed", "machine.unlinked_by_machine": return "Computer unlinked"
        case "machine.renamed": return "Computer renamed"
        case "machine.online": return "Computer connected"
        case "relay.action": return "\(d?["method"]?.string ?? "") \(d?["path"]?.string ?? "")"
        default: return e.action
        }
    }
}
