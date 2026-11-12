import SwiftUI
import UIKit

/// Connect a computer: pick how it's reached, then either the SSH setup
/// (host key check → install → pair → tunnel) or the relay link code.
struct AddMachineView: View {
    enum Route: Hashable { case ssh(String), windows, relay }
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("How is this computer reached?").font(Theme.title)
                    WelcomeOption(icon: "server.rack", title: "Linux server or VPS", detail: "Over SSH. Hetzner, DigitalOcean, AWS, a Raspberry Pi, a home server…") { path.append(.ssh("linux")) }
                        .accessibilityIdentifier("add.linux")
                    WelcomeOption(icon: "laptopcomputer", title: "Mac", detail: "Over SSH: turn on System Settings → General → Sharing → Remote Login. Same network, Tailscale or a reachable address.") { path.append(.ssh("mac")) }
                        .accessibilityIdentifier("add.mac")
                    WelcomeOption(icon: "pc", title: "Windows PC", detail: "Through WSL2 (Ubuntu). Agents, terminals and tmux run inside WSL.") { path.append(.windows) }
                        .accessibilityIdentifier("add.windows")
                    WelcomeOption(icon: "antenna.radiowaves.left.and.right", title: "A computer the \(Device.name) can't reach", detail: "Home or office machines behind a router. The companion connects out to your account's relay; nothing is opened to the internet. Needs a Musa Control account.") { path.append(.relay) }
                        .accessibilityIdentifier("add.relay")
                    Text("Every option keeps the companion on the machine's loopback interface. You choose what the agents may do; their own approval prompts stay in charge.")
                        .font(Theme.caption).foregroundStyle(Theme.textFaint).padding(.top, 4)
                }
                .padding(20).frame(maxWidth: 620).frame(maxWidth: .infinity)
            }
            .background(Theme.bg)
            .navigationTitle("Add a computer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .navigationDestination(for: Route.self) { r in
                switch r {
                case .ssh(let kind): SSHSetupView(kind: kind) { m in finish(m) }
                case .windows: WindowsGuideView { path.append($0) }
                case .relay: RelayLinkView { m in finish(m) }
                }
            }
        }
    }

    func finish(_ m: Machine) {
        dismiss()
        Task { await app.activate(m) }
    }
}

// MARK: - SSH

struct SSHSetupView: View {
    let kind: String
    let onDone: (Machine) -> Void
    @State private var setup = RemoteSetup()
    @State private var busy = false

    var body: some View {
        Form {
            switch setup.phase {
            case .form: form
            case .verifyHost: verify
            case .running, .done, .failed: progress
            }
        }
        .navigationTitle(kind == "mac" ? "Mac over SSH" : "Server over SSH")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(setup.phase == .running)
    }

    @ViewBuilder var form: some View {
        SwiftUI.Section {
            TextField(kind == "mac" ? "my-mac.local or 100.x.y.z" : "server.example.com or 203.0.113.7", text: $setup.host)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).accessibilityIdentifier("ssh.host")
            TextField("Port", text: $setup.port).keyboardType(.numberPad)
            TextField("Username", text: $setup.user).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("ssh.user")
            TextField("Name in Musa Control (optional)", text: $setup.name)
        } header: { Text("Computer") }
        SwiftUI.Section {
            Picker("Sign in with", selection: $setup.usePassword) {
                Text("Password (once)").tag(true)
                Text("This \(Device.name)'s key").tag(false)
            }
            if setup.usePassword {
                SecureField("SSH password", text: $setup.password).textContentType(.password).accessibilityIdentifier("ssh.password")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Add this line to ~/.ssh/authorized_keys on the computer first:").font(Theme.caption).foregroundStyle(Theme.textDim)
                    Text(SSHKeys.openSSHPublicKey(comment: "musa-control")).font(Theme.monoSmall).textSelection(.enabled).lineLimit(3)
                    Button("Copy key") { UIPasteboard.general.string = SSHKeys.openSSHPublicKey(comment: "musa-control") }
                }
            }
        } header: { Text("Sign-in") } footer: {
            Text("The password is used once to install this \(Device.name)'s own SSH key, then forgotten. It's never stored or sent anywhere except to the computer over SSH.")
        }
        if Account.shared.signedIn {
            SwiftUI.Section { Toggle("Also link to my account", isOn: $setup.linkAccount) } footer: {
                Text("Adds notifications from this computer and lets you reach it through the relay when SSH isn't available.")
            }
        }
        SwiftUI.Section {
            if let e = setup.error { Text(e).foregroundStyle(Theme.red).font(Theme.caption) }
            Button { busy = true; Task { await setup.checkHostKey(); busy = false } } label: {
                HStack { if busy { ProgressView().controlSize(.small) }; Text("Continue") }
            }
            .disabled(!setup.formValid || busy).accessibilityIdentifier("ssh.continue")
        } footer: {
            Text(kind == "mac" ? "Needs Node.js 22 (brew install node) and tmux (brew install tmux) on the Mac." : "Needs Node.js 22 and tmux on the server (e.g. apt install tmux; Node from nodejs.org or nvm). No root needed.")
        }
    }

    @ViewBuilder var verify: some View {
        SwiftUI.Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Check the computer's identity", systemImage: "checkmark.shield").font(Theme.title)
                Text("This is the first connection to \(setup.host), so its host key isn't known yet. If you can, compare it with the output of this command on the computer:")
                    .font(Theme.caption).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
                Text("ssh-keygen -lf /etc/ssh/ssh_host_\((setup.keyType ?? "ssh-ed25519").replacingOccurrences(of: "ssh-", with: ""))_key.pub").font(Theme.monoSmall).textSelection(.enabled)
                Text(setup.fingerprint ?? "").font(.system(size: 14, weight: .semibold, design: .monospaced)).textSelection(.enabled).padding(.top, 4)
                    .accessibilityIdentifier("ssh.fingerprint")
                Text(setup.keyType ?? "").font(Theme.caption).foregroundStyle(Theme.textFaint)
            }
        } footer: { Text("Musa Control pins this key. If it ever changes, connections are refused.") }
        SwiftUI.Section {
            Button("Trust and set up") { Task { await setup.run() } }.accessibilityIdentifier("ssh.trust")
            Button("Back", role: .cancel) { setup.phase = .form; setup.fingerprint = nil }
        }
    }

    @ViewBuilder var progress: some View {
        SwiftUI.Section {
            ForEach(setup.steps) { s in
                HStack(alignment: .top, spacing: 10) {
                    Group {
                        switch s.state {
                        case .waiting: Image(systemName: "circle").foregroundStyle(Theme.textFaint)
                        case .running: ProgressView().controlSize(.small)
                        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
                        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.red)
                        case .skipped: Image(systemName: "minus.circle").foregroundStyle(Theme.textFaint)
                        }
                    }
                    .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title).font(.system(size: 14))
                        if let n = s.note { Text(n).font(Theme.caption).foregroundStyle(s.state == .failed ? Theme.red : Theme.textDim).fixedSize(horizontal: false, vertical: true) }
                    }
                }
            }
        } header: { Text("Setting up \(setup.name.isEmpty ? setup.host : setup.name)") }
        if setup.phase == .done, let m = setup.machine {
            SwiftUI.Section {
                Button("Open \(m.name)") { onDone(m) }.font(.system(size: 15, weight: .semibold)).accessibilityIdentifier("ssh.open")
            } footer: { Text("Next: sign in to Claude Code, Codex or Gemini CLI on this computer from Machines & AI.") }
        }
        if setup.phase == .failed {
            SwiftUI.Section {
                Button("Try again") { setup.phase = .form }
            } footer: { Text("Nothing was left half-installed that a second run won't replace.") }
        }
    }
}

// MARK: - Windows

struct WindowsGuideView: View {
    let go: (AddMachineView.Route) -> Void
    var body: some View {
        Form {
            SwiftUI.Section {
                Text("Musa Control runs agents, terminals and tmux inside WSL2, the Linux environment built into Windows 10/11.").fixedSize(horizontal: false, vertical: true)
                StepText(n: 1, text: "In PowerShell (as administrator): wsl --install -d Ubuntu, then restart.")
                StepText(n: 2, text: "In Ubuntu: sudo apt update && sudo apt install -y tmux nodejs npm (or install Node 22 with nvm).")
                StepText(n: 3, text: "Install your AI tools there: npm install -g @anthropic-ai/claude-code @openai/codex @google/gemini-cli (or do it later from the app).")
            } header: { Text("Prepare WSL") }
            SwiftUI.Section {
                Button("Link with a code (recommended)") { go(.relay) }
                Button("Connect over SSH into WSL") { go(.ssh("linux")) }
            } header: { Text("Then connect") } footer: {
                Text("The link-code route works behind any router. SSH into WSL needs openssh-server running in Ubuntu and a port the iPad can reach (for example over Tailscale).")
            }
        }
        .navigationTitle("Windows PC")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct StepText: View {
    let n: Int; let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.onAccent).frame(width: 20, height: 20).background(Theme.accent, in: Circle())
            Text(text).font(.system(size: 14)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Relay

struct RelayLinkView: View {
    let onDone: (Machine) -> Void
    @State private var account = Account.shared
    @State private var name = ""
    @State private var code: LinkCode?
    @State private var error: String?
    @State private var waiting = false
    @State private var known: Set<String> = []
    @State private var showSignIn = false

    var installCommand: String {
        let base = CloudAuth.baseURL.absoluteString
        return "curl -fsSL \(base)/companion/install.sh | sh -s -- --link \(code?.code ?? "CODE")"
    }

    var body: some View {
        Form {
            if !account.signedIn {
                SwiftUI.Section {
                    Text("Linking a computer through the relay needs a Musa Control account.").fixedSize(horizontal: false, vertical: true)
                    Button("Sign in or create an account") { showSignIn = true }
                }
            } else if let code {
                SwiftUI.Section {
                    Text(code.code).font(.system(size: 34, weight: .bold, design: .monospaced)).frame(maxWidth: .infinity).textSelection(.enabled)
                        .accessibilityIdentifier("relay.code")
                    Text("Valid for 15 minutes, once.").font(Theme.caption).foregroundStyle(Theme.textDim).frame(maxWidth: .infinity)
                } header: { Text("Link code") }
                SwiftUI.Section {
                    StepText(n: 1, text: "On the computer (macOS, Linux or Ubuntu on WSL), open a terminal as your normal user.")
                    StepText(n: 2, text: "Run:")
                    Text(installCommand).font(Theme.monoSmall).textSelection(.enabled)
                    Button("Copy command") { UIPasteboard.general.string = installCommand }
                    Text("Already installed? Run: musa-companion link \(code.code) --relay \(CloudAuth.baseURL.absoluteString)").font(Theme.caption).foregroundStyle(Theme.textDim).textSelection(.enabled)
                } header: { Text("Install and link") } footer: {
                    Text("The companion needs Node.js 22. It connects out to the relay over TLS and listens only on 127.0.0.1. Remove the computer from Machines & AI at any time to cut it off.")
                }
                SwiftUI.Section {
                    HStack { ProgressView().controlSize(.small); Text("Waiting for the computer to connect…").foregroundStyle(Theme.textDim) }
                }
            } else {
                SwiftUI.Section {
                    TextField("Name (e.g. Studio Mac)", text: $name)
                    Button("Create link code") { Task { await create() } }.accessibilityIdentifier("relay.create")
                } footer: { Text("You'll run one command on the computer with this code.") }
            }
            if let error { SwiftUI.Section { Text(error).foregroundStyle(Theme.red).font(Theme.caption) } }
        }
        .navigationTitle("Link a computer")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSignIn) { EmailSignInSheet() }
        .task(id: code?.code) { await poll() }
    }

    func create() async {
        error = nil
        known = Set(account.machines.map(\.id))
        do { code = try await account.linkCode(name: name.isEmpty ? nil : name) } catch { self.error = error.localizedDescription }
    }

    func poll() async {
        guard code != nil else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await account.refreshMachines()
            if let c = account.machines.first(where: { !known.contains($0.id) && $0.online }),
               let m = MachineStore.all.first(where: { $0.cloudId == c.id }) {
                onDone(m)
                return
            }
        }
    }
}
