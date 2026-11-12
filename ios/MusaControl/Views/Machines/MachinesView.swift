import SwiftUI
import UIKit

/// Machines & AI: the active computer (health, what it can do, its AI
/// subscriptions), every saved computer, and the account.
struct MachinesView: View {
    @Environment(AppModel.self) private var app
    @State private var account = Account.shared
    @State private var me: Me?
    @State private var renaming: Machine?
    @State private var newName = ""
    @State private var removing: Machine?
    @State private var showAccount = false
    @State private var showSignIn = false

    var body: some View {
        @Bindable var app = app
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let m = app.activeMachine { activeCard(m) }
                ProvidersPanel()
                machineList
                accountCard
            }
            .padding(20).frame(maxWidth: 880).frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
        .task(id: app.activeMachine?.id) { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $app.showAddMachine) { AddMachineView() }
        .sheet(isPresented: $showAccount) { AccountView() }
        .sheet(isPresented: $showSignIn) { EmailSignInSheet() }
        .alert("Rename computer", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") { if let m = renaming { Task { await app.renameMachine(m, to: newName) } }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Remove \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) { if let m = removing { Task { await app.removeMachine(m) } }; removing = nil }
        } message: {
            Text(removing?.kind == .relay ? "The computer is unlinked from your account and can't be reached through the relay any more. Its files and running sessions stay as they are." : "This \(Device.name) forgets the computer and its token. Its files and running sessions stay as they are.")
        }
    }

    func load() async {
        me = try? await app.client.get("/api/me", as: Me.self)
        if account.hasToken { await account.refreshMachines(); app.reloadMachines() }
    }

    // MARK: Active machine

    func activeCard(_ m: Machine) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: m.symbol).font(.system(size: 26)).foregroundStyle(Theme.accent).frame(width: 40)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) { Text(m.name).font(.system(size: 20, weight: .semibold)); ConnectionDot() }
                    Text("\(m.kindLabel) · \(m.subtitle)").font(Theme.caption).foregroundStyle(Theme.textDim)
                    if let os = me?.capabilities?.os { Text(os + (me?.server?.user.map { " · \($0)" } ?? "")).font(Theme.caption).foregroundStyle(Theme.textFaint) }
                }
                Spacer()
                Menu {
                    Button("Rename…") { newName = m.name; renaming = m }
                    Button("Reconnect") { Task { await app.connect() } }
                    Button("Remove…", role: .destructive) { removing = m }
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 18)) }
            }
            if let c = me?.capabilities {
                FlowChips(items: [
                    ("Terminals", c.terminal ?? false), ("Agent sessions", c.agents ?? false), ("Git", c.git ?? false), ("GitHub", c.github ?? false),
                    ("Live previews", c.previews ?? false), ("Remote desktop", c.remoteDesktop ?? false), ("Notifications", c.push ?? false),
                ])
                if c.terminal == false { Text("tmux isn't installed on this computer, so terminals and agent sessions can't start. Install it (apt install tmux / brew install tmux).").font(Theme.caption).foregroundStyle(Theme.yellow).fixedSize(horizontal: false, vertical: true) }
            } else if case .offline(let msg) = app.phase {
                Text(msg).font(Theme.caption).foregroundStyle(Theme.red)
            }
        }
        .card()
    }

    // MARK: All machines

    var machineList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Computers").font(Theme.title)
                Spacer()
                Button { app.showAddMachine = true } label: { Label("Add", systemImage: "plus") }.accessibilityIdentifier("machines.add")
            }
            ForEach(app.machines) { m in
                let cloud = account.machines.first { $0.id == m.cloudId }
                HStack(spacing: 12) {
                    Image(systemName: m.symbol).foregroundStyle(Theme.textDim).frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.name).font(.system(size: 15, weight: m.id == app.activeMachine?.id ? .semibold : .regular))
                        Text("\(m.kindLabel) · \(m.subtitle)").font(Theme.caption).foregroundStyle(Theme.textDim).lineLimit(1)
                    }
                    Spacer()
                    if m.kind == .relay { Pill(text: cloud?.online == true ? "online" : "offline", color: cloud?.online == true ? Theme.green : Theme.textFaint) }
                    if m.id == app.activeMachine?.id { Pill(text: "active", color: Theme.accent) }
                    else { Button("Switch") { Task { await app.activate(m) } }.buttonStyle(.bordered).accessibilityIdentifier("machines.switch.\(m.id)") }
                }
                .padding(.vertical, 8).padding(.horizontal, 12)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.line))
                .contextMenu {
                    Button("Rename…") { newName = m.name; renaming = m }
                    Button("Remove…", role: .destructive) { removing = m }
                }
            }
        }
    }

    // MARK: Account

    var accountCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Account").font(Theme.title)
            if account.signedIn, let u = account.user {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(u.name ?? u.email ?? "Musa Control account").font(.system(size: 15, weight: .semibold))
                        Text(u.email ?? "Signed in with Apple").font(Theme.caption).foregroundStyle(Theme.textDim)
                    }
                    Spacer()
                    Button("Manage") { showAccount = true }.buttonStyle(.bordered).accessibilityIdentifier("account.manage")
                }
            } else {
                Text("Optional. Sign in to link computers that aren't reachable directly, and to get their notifications.").font(Theme.caption).foregroundStyle(Theme.textDim)
                Button("Sign in") { showSignIn = true }.buttonStyle(.bordered)
            }
        }
        .card()
    }
}

/// Wrapping row of capability chips.
struct FlowChips: View {
    let items: [(String, Bool)]
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { chips }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) { ForEach(Array(items.prefix(4).enumerated()), id: \.offset) { _, i in chip(i) } }
                HStack(spacing: 6) { ForEach(Array(items.dropFirst(4).enumerated()), id: \.offset) { _, i in chip(i) } }
            }
        }
    }
    @ViewBuilder var chips: some View { ForEach(Array(items.enumerated()), id: \.offset) { _, i in chip(i) } }
    func chip(_ i: (String, Bool)) -> some View {
        Label(i.0, systemImage: i.1 ? "checkmark" : "minus").font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(i.1 ? Theme.green.opacity(0.13) : Theme.raised, in: Capsule())
            .foregroundStyle(i.1 ? Theme.green : Theme.textFaint)
    }
}

// MARK: - AI providers on the active machine

struct ProviderInfo: Codable, Identifiable, Hashable {
    struct Auth: Codable, Hashable { let signedIn: Bool?; let method: String?; let detail: String? }
    struct Key: Codable, Hashable { let set: Bool; let last4: String? }
    let id: String; let name: String; let vendor: String; let plan: String; let docs: String?; let npmPackage: String?
    let installed: Bool; let version: String?; let auth: Auth; let apiKey: Key
    enum CodingKeys: String, CodingKey { case id, name, vendor, plan, docs, npmPackage = "package", installed, version, auth, apiKey }
}
struct TmuxSessionRef: Codable, Hashable, Identifiable { let tmux: String; var id: String { tmux } }

struct ProvidersPanel: View {
    @Environment(AppModel.self) private var app
    @State private var providers: [ProviderInfo] = []
    @State private var loading = false
    @State private var error: String?
    @State private var login: TmuxSessionRef?
    @State private var loginTitle = ""
    @State private var keyFor: ProviderInfo?
    @State private var installFor: ProviderInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("AI subscriptions on this computer").font(Theme.title)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                IconButton(systemName: "arrow.clockwise", help: "Check again") { Task { await load(fresh: true) } }
            }
            Text("Each tool signs in on the computer with its own official login. Musa Control never sees your provider password or session token.")
                .font(Theme.caption).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(Theme.caption).foregroundStyle(Theme.red) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 10)], spacing: 10) {
                ForEach(providers) { p in card(p) }
            }
        }
        .task(id: app.activeMachine?.id) { await load(fresh: false) }
        .sheet(item: $login, onDismiss: { Task { await load(fresh: true) } }) { ref in ProviderLoginSheet(ref: ref, title: loginTitle) }
        .sheet(item: $keyFor, onDismiss: { Task { await load(fresh: true) } }) { p in APIKeySheet(provider: p) }
        .confirmationDialog("Install \(installFor?.name ?? "")?", isPresented: Binding(get: { installFor != nil }, set: { if !$0 { installFor = nil } }), titleVisibility: .visible) {
            Button("Install with npm") { if let p = installFor { Task { await install(p) } } }
        } message: { Text("Runs npm install -g \(installFor?.npmPackage ?? "") on this computer. You can watch it in the terminal.") }
    }

    func card(_ p: ProviderInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.name).font(.system(size: 15, weight: .semibold))
                    Text(p.vendor + (p.version.map { " · \($0)" } ?? "")).font(Theme.caption).foregroundStyle(Theme.textDim)
                }
                Spacer()
                status(p)
            }
            Text(p.plan).font(Theme.caption).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if !p.installed {
                    Button("Install…") { installFor = p }.buttonStyle(.borderedProminent)
                } else if p.auth.signedIn != true {
                    Button("Sign in") { Task { await startLogin(p) } }.buttonStyle(.borderedProminent).accessibilityIdentifier("provider.signin.\(p.id)")
                } else {
                    Button("Sign in again") { Task { await startLogin(p) } }.buttonStyle(.bordered)
                }
                Button(p.apiKey.set ? "API key ··\(p.apiKey.last4 ?? "")" : "Use API key") { keyFor = p }.buttonStyle(.bordered).disabled(!p.installed && p.id == "codex")
            }
            .controlSize(.small)
        }
        .card()
    }

    @ViewBuilder func status(_ p: ProviderInfo) -> some View {
        if !p.installed { Pill(text: "not installed", color: Theme.textFaint) }
        else if p.auth.signedIn == true { Pill(text: p.auth.method ?? "signed in", color: Theme.green) }
        else if p.auth.signedIn == nil { Pill(text: p.auth.method ?? "unknown", color: Theme.yellow) }
        else { Pill(text: "not signed in", color: Theme.yellow) }
    }

    func load(fresh: Bool) async {
        loading = true; defer { loading = false }
        let q: [String: String?] = fresh ? ["fresh": "1"] : [:]
        do { providers = try await app.client.get("/api/providers", q, as: [ProviderInfo].self, timeout: 45); error = nil }
        catch let e as GatewayError where e.status == 404 { error = "This computer's companion is older and doesn't report AI tools yet. Update it from Add a computer."; providers = [] }
        catch { self.error = error.localizedDescription }
    }

    func startLogin(_ p: ProviderInfo) async {
        do { login = try await app.client.send("POST", "/api/providers/\(p.id)/login", [:], as: TmuxSessionRef.self); loginTitle = "Sign in to \(p.name)" }
        catch { self.error = error.localizedDescription }
    }

    func install(_ p: ProviderInfo) async {
        do { let r = try await app.client.send("POST", "/api/providers/\(p.id)/install", ["confirm": true], as: TmuxSessionRef.self); app.attachTerminal(r.tmux) }
        catch { self.error = error.localizedDescription }
    }
}

struct ProviderLoginState: Codable { let exists: Bool; let screen: String?; let urls: [String]?; let deviceCode: String?; let wantsCode: Bool?; let finished: Bool? }

/// The provider's own sign-in, running on the computer: its link (opened
/// here in Safari), its device code, and a box for pasting the code back.
struct ProviderLoginSheet: View {
    let ref: TmuxSessionRef
    let title: String
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var state: ProviderLoginState?
    @State private var code = ""
    @State private var sent = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if let urls = state?.urls, !urls.isEmpty {
                    SwiftUI.Section {
                        ForEach(urls, id: \.self) { u in
                            Button { if let url = URL(string: u) { openURL(url) } } label: { Label("Open the sign-in page", systemImage: "safari") }
                        }
                        if let dc = state?.deviceCode {
                            HStack {
                                Text(dc).font(.system(size: 26, weight: .bold, design: .monospaced)).textSelection(.enabled)
                                Spacer()
                                Button("Copy") { UIPasteboard.general.string = dc }
                            }
                        }
                    } header: { Text("1. Sign in with the provider") } footer: {
                        Text("Sign in on the provider's own page. When it shows a code, paste it below (or it finishes by itself for device sign-in).")
                    }
                }
                if state?.wantsCode == true || (state?.urls?.isEmpty == false && state?.deviceCode == nil) {
                    SwiftUI.Section {
                        TextField("Paste the code", text: $code).textInputAutocapitalization(.never).autocorrectionDisabled().font(Theme.mono)
                        Button("Send to the computer") { Task { await send() } }.disabled(code.isEmpty)
                        if sent { Text("Sent.").font(Theme.caption).foregroundStyle(Theme.green) }
                    } header: { Text("2. Paste the code") } footer: { Text("The code goes straight to the sign-in running on your computer and isn't kept anywhere.") }
                }
                SwiftUI.Section {
                    ScrollView(.horizontal) {
                        Text(state?.screen ?? "Starting…").font(Theme.monoSmall).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 160)
                    Button("Open in Terminal") { app.attachTerminal(ref.tmux); dismiss() }
                } header: { Text("On the computer") }
                if let error { Text(error).foregroundStyle(Theme.red).font(Theme.caption) }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { Task { _ = try? await app.client.raw(app.client.request("DELETE", "/api/provider-sessions/\(ref.tmux)")); dismiss() } } } }
            .task { await poll() }
        }
    }

    func poll() async {
        while !Task.isCancelled {
            if let s = try? await app.client.get("/api/provider-sessions/\(ref.tmux)", as: ProviderLoginState.self) { state = s; if !s.exists { return } }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }

    func send() async {
        do { _ = try await app.client.send("POST", "/api/provider-sessions/\(ref.tmux)/input", ["text": code], as: OK.self); code = ""; sent = true }
        catch { self.error = error.localizedDescription }
    }
}

struct APIKeySheet: View {
    let provider: ProviderInfo
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                SwiftUI.Section {
                    SecureField("\(provider.vendor) API key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled().font(Theme.mono)
                } footer: {
                    Text("Optional, and billed by \(provider.vendor) per use. Saved only on this computer (readable by your user only) and given to \(provider.name) sessions started from Musa Control. It's never sent back to the app or stored by Musa Control's servers.")
                }
                if let error { Text(error).foregroundStyle(Theme.red).font(Theme.caption) }
                Button { Task { await save() } } label: { HStack { if busy { ProgressView().controlSize(.small) }; Text("Save on the computer") } }.disabled(key.isEmpty || busy)
                if provider.apiKey.set {
                    Button("Remove saved key", role: .destructive) { Task { _ = try? await app.client.raw(app.client.request("DELETE", "/api/providers/\(provider.id)/key")); dismiss() } }
                }
            }
            .navigationTitle(provider.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    func save() async {
        busy = true; defer { busy = false }
        do { _ = try await app.client.send("PUT", "/api/providers/\(provider.id)/key", ["key": key], as: OK.self); key = ""; dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
