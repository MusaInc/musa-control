import SwiftUI

/// First run: pair this iPad with the gateway using the workspace password.
/// The password is sent once over TLS and never stored; the gateway returns a
/// device token that lives in the Keychain.
struct PairingView: View {
    @Environment(AppModel.self) private var app
    @State private var server = "https://musastudios.co.uk/control"
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focus: Bool

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                Image("SidebarMark").resizable().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 6) {
                    Text("Musa Control").font(.system(size: 28, weight: .semibold))
                    Text("Pair this iPad with your Musa Studios server. Use the same password as the workspace sign-in; it's checked once and never stored on the iPad.")
                        .font(.system(size: 14)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Gateway").font(Theme.label).foregroundStyle(Theme.textDim)
                    TextField("https://…/control", text: $server)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .padding(10).background(Theme.raised, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityIdentifier("pair.server")
                    Text("Workspace password").font(Theme.label).foregroundStyle(Theme.textDim).padding(.top, 6)
                    SecureField("Password", text: $password)
                        .focused($focus).submitLabel(.go).onSubmit(submit)
                        .padding(10).background(Theme.raised, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityIdentifier("pair.password")
                }
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").font(Theme.label).foregroundStyle(Theme.red) }
                Button(action: submit) {
                    HStack { if busy { ProgressView().controlSize(.small) }; Text(busy ? "Pairing…" : "Pair this iPad") }
                        .font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 44)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10)).foregroundStyle(Theme.onAccent)
                }
                .buttonStyle(.plain).disabled(busy || password.isEmpty)
                Text("Everything runs on the server. Agents, builds and terminals keep going when the iPad sleeps or loses signal.")
                    .font(Theme.caption).foregroundStyle(Theme.textFaint)
            }
            .frame(maxWidth: 420).padding(32)
        }
        .onAppear { focus = true }
    }

    func submit() {
        guard !password.isEmpty, !busy else { return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do { try await app.pair(server: server, password: password); password = "" }
            catch { self.error = error.localizedDescription }
        }
    }
}
