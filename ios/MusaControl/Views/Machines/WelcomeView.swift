import SwiftUI
import AuthenticationServices

/// First run (no machine yet). An account is optional: SSH machines and the
/// Musa Studios gateway work without one; the relay (computers the iPad
/// can't reach directly) and notifications from those need it.
struct WelcomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @State private var account = Account.shared
    @State private var showEmail = false
    @State private var showPairing = false
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        @Bindable var app = app
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 12) {
                        Image("SidebarMark").resizable().frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Musa Control").font(.system(size: 28, weight: .semibold))
                            Text("Your AI coding agents, on your own machines.").font(.system(size: 15)).foregroundStyle(Theme.textDim)
                        }
                    }
                    features
                    if account.signedIn { signedIn } else { signInOptions }
                    if let error { Label(error, systemImage: "exclamationmark.triangle.fill").font(Theme.label).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true) }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Or without an account").font(Theme.label).foregroundStyle(Theme.textDim)
                        WelcomeOption(icon: "terminal", title: "Connect a computer over SSH", detail: "A VPS, Linux box or Mac with SSH. The companion runs on that machine's loopback only; the \(Device.name) reaches it through its own encrypted SSH tunnel.") { app.showAddMachine = true }
                            .accessibilityIdentifier("welcome.ssh")
                        WelcomeOption(icon: "server.rack", title: "Musa Studios server", detail: "Pair with the studio gateway using the workspace password.") { showPairing = true }
                            .accessibilityIdentifier("welcome.studio")
                    }
                    Text("Musa Control never asks for your Anthropic, OpenAI or Google password. Each AI tool signs in on your own machine with its own login, and your subscriptions stay yours.")
                        .font(Theme.caption).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 560).padding(28).frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $showEmail) { EmailSignInSheet() }
        .sheet(isPresented: $showPairing) { NavigationStack { PairingView().toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { showPairing = false } } } } }
        .sheet(isPresented: $app.showAddMachine) { AddMachineView() }
    }

    var features: some View {
        VStack(alignment: .leading, spacing: 10) {
            FeatureLine(icon: "sparkles", text: "Start, watch and steer Claude Code, Codex and Gemini CLI sessions")
            FeatureLine(icon: "checkmark.shield", text: "Approve or reject their actions, even from a notification")
            FeatureLine(icon: "photo.on.rectangle", text: "Screenshots, live previews, diffs, files, terminals and git")
            FeatureLine(icon: "moon.zzz", text: "Work keeps running on your machine when the \(Device.name) sleeps")
        }
        .card()
    }

    var signInOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            SignInWithAppleButton(.continue) { req in account.prepareApple(req) } onCompletion: { result in
                Task { busy = true; defer { busy = false }; do { try await account.completeApple(result); error = nil } catch { self.error = error.localizedDescription } }
            }
            .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
            .frame(height: 46).clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityIdentifier("welcome.apple")
            Button { showEmail = true } label: {
                Label("Continue with email", systemImage: "envelope").font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 44)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain).accessibilityIdentifier("welcome.email")
            Text("An account lets you reach computers that aren't reachable from the internet (through an outbound relay) and get their notifications.")
                .font(Theme.caption).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
        }
    }

    var signedIn: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Signed in\(account.user?.name.map { " as \($0)" } ?? "")").font(Theme.title)
            Text("Connect your first computer. You can add more later in Machines & AI.").font(Theme.caption).foregroundStyle(Theme.textDim)
            Button { app.showAddMachine = true } label: {
                Label("Connect a computer", systemImage: "plus").font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 46)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10)).foregroundStyle(Theme.onAccent)
            }
            .buttonStyle(.plain).accessibilityIdentifier("welcome.connect")
            Button("Sign out") { Task { await account.signOut() } }.font(Theme.caption)
        }
        .card()
    }
}

struct FeatureLine: View {
    let icon: String; let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 20)
            Text(text).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct WelcomeOption: View {
    let icon: String; let title: String; let detail: String; let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon).font(.system(size: 18)).foregroundStyle(Theme.accent).frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(detail).font(Theme.caption).foregroundStyle(Theme.textDim).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textFaint)
            }
            .card()
        }
        .buttonStyle(.plain)
    }
}

/// Email sign-in / sign-up (Sign in with Apple is the quicker path).
struct EmailSignInSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var account = Account.shared
    @State private var creating = false
    @State private var email = ""
    @State private var password = ""
    @State private var name = ""
    @State private var busy = false
    @State private var error: String?
    @State private var showServer = false
    @AppStorage("account.cloudURL") private var cloudURL = CloudAuth.defaultURL

    var body: some View {
        NavigationStack {
            Form {
                Picker("", selection: $creating) { Text("Sign in").tag(false); Text("Create account").tag(true) }.pickerStyle(.segmented)
                SwiftUI.Section {
                    if creating { TextField("Name", text: $name).textContentType(.name) }
                    TextField("Email", text: $email).textContentType(.username).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("email.address")
                    SecureField(creating ? "Password (10+ characters)" : "Password", text: $password).textContentType(creating ? .newPassword : .password)
                        .accessibilityIdentifier("email.password")
                } footer: {
                    if creating { Text("Use a password you don't use anywhere else. Your AI provider accounts are never connected to this password.") }
                }
                if let error { Text(error).foregroundStyle(Theme.red).font(Theme.caption) }
                Button { submit() } label: { HStack { if busy { ProgressView().controlSize(.small) }; Text(creating ? "Create account" : "Sign in") } }
                    .disabled(busy || email.isEmpty || password.isEmpty)
                    .accessibilityIdentifier("email.submit")
                DisclosureGroup("Account server", isExpanded: $showServer) {
                    TextField("https://…", text: $cloudURL).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).font(Theme.monoSmall)
                    Text("Only change this if you run your own Musa Control account service.").font(Theme.caption).foregroundStyle(Theme.textDim)
                }
            }
            .navigationTitle(creating ? "Create account" : "Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    func submit() {
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                if creating { try await account.register(email: email, password: password, name: name) }
                else { try await account.signIn(email: email, password: password) }
                password = ""
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
