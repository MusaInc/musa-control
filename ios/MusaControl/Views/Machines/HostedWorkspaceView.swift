import SwiftUI

struct HostedWorkspaceView: View {
    @Environment(AppModel.self) private var app
    let onFinish: () -> Void
    @State private var server = ""
    @State private var name = "Hafsa"
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            SwiftUI.Section {
                TextField("Workspace name", text: $name)
                TextField("https://…", text: $server).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("hosted.address")
                SecureField("One-time connection code", text: $code).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .accessibilityIdentifier("hosted.code")
            } header: { Text("Connect your workspace") } footer: {
                Text("Use the address and fresh code from your administrator. The code works once and expires after 10 minutes. You do not need an SSH password or a Musa account.")
            }
            SwiftUI.Section {
                Text("Next, open Machines & AI → Codex → Sign in. Open the OpenAI link on this iPad and use your own ChatGPT account. Then open Projects to start building.")
            } header: { Text("Your own ChatGPT subscription") }
            if let error { Text(error).foregroundStyle(Theme.red) }
            Button { connect() } label: {
                HStack { if busy { ProgressView() }; Text("Connect workspace") }
            }.disabled(busy || server.isEmpty || code.isEmpty).accessibilityIdentifier("hosted.connect")
        }
        .navigationTitle("Hosted workspace")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onFinish) } }
    }

    func connect() {
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                try await app.pairHosted(server: server, code: code, name: name)
                code = ""
                onFinish()
            } catch { self.error = error.localizedDescription }
        }
    }
}
