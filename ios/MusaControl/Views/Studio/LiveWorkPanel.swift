import SwiftUI

struct LiveWorkSnapshot: Decodable {
    struct Browser: Decodable { let ok: Bool; let humanCheck: Bool?; let message: String?; let display: String }
    struct Pending: Decodable, Identifiable {
        let id: String
        let commandId: String
        let command: String
        let warnings: [String]
        let reason: String?
        let verification: Bool
    }
    struct Current: Decodable { let command: String; let startedAt: Double? }
    struct Command: Decodable, Identifiable {
        let id: String
        let command: String?
        let output: String?
        let exitCode: Int?
        let durationMs: Double?
        let sent: Bool
        let refused: Bool
    }

    let state: String
    let active: Bool
    let controllable: Bool
    let browser: Browser
    let activity: String?
    let step: Int
    let id: String?
    let project: String?
    let title: String?
    let request: String?
    let conversation: String?
    let nativeControl: Bool
    let assistant: String?
    let streaming: Bool
    let issue: String?
    let verification: String?
    let verificationState: String?
    let shell: String?
    let canResume: Bool
    let canMessage: Bool
    let canReattach: Bool
    let canInterrupt: Bool
    let pending: Pending?
    let current: Current?
    let commands: [Command]
}

private struct LiveWorkTerminalTail: Decodable { let text: String }

struct LiveWorkPanel: View {
    @Environment(AppModel.self) private var app
    @Environment(DesktopStore.self) private var desktop
    @Environment(\.openURL) private var openURL
    @State private var snapshot: LiveWorkSnapshot?
    @State private var request = ""
    @State private var guidance = ""
    @State private var requestId = UUID().uuidString
    @State private var guidanceId = UUID().uuidString
    @State private var showBrowser = false
    @State private var expandBrowser = false
    @State private var selectedContent = "conversation"
    @State private var terminal = ""
    @State private var transportIssue: String?
    @State private var actionIssue: String?
    @State private var actionInFlight = false
    @State private var commandDecision: CommandDecision?
    @State private var confirmStop = false

    private struct CommandDecision: Identifiable {
        let command: LiveWorkSnapshot.Pending
        let action: String
        var id: String { command.commandId + action }
    }

    private let endpoint = "/api/live-work"

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 930
            if wide && showBrowser && !expandBrowser {
                HStack(spacing: 0) {
                    workstation(inlineBrowser: false).frame(width: geo.size.width * 0.52)
                    Divider()
                    browser
                }
            } else {
                workstation(inlineBrowser: showBrowser && !expandBrowser)
            }
        }
        .background(Theme.bg)
        .accessibilityIdentifier("studio.liveWork")
        .task(id: app.activeMachine?.id) {
            snapshot = nil
            transportIssue = nil
            actionIssue = nil
            showBrowser = false
            terminal = ""
            await poll()
        }
        .onDisappear { app.chatBrowser.suspendInput() }
        .fullScreenCover(isPresented: $expandBrowser) {
            VStack(spacing: 0) {
                HStack {
                    Text("ChatGPT").font(Theme.title)
                    Spacer()
                    Button("Done") { expandBrowser = false }.keyboardShortcut(.cancelAction)
                }
                .padding(12).background(Theme.surface)
                browser
            }.background(Theme.bg)
        }
        .sheet(item: $commandDecision) { decision in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        code(decision.command.command)
                        if let reason = decision.command.reason { Text(reason).font(.callout) }
                        ForEach(decision.command.warnings, id: \.self) { Text($0).foregroundStyle(Theme.yellow) }
                    }.padding()
                }
                .navigationTitle(decision.action == "approve" ? "Review command" : "Reject command")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Back") { commandDecision = nil } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(decision.action == "approve" ? "Run command" : "Reject", role: decision.action == "approve" ? nil : .destructive) {
                            commandDecision = nil
                            control(decision.action, ["pendingId": decision.command.id, "commandId": decision.command.commandId, "confirm": true])
                        }.disabled(actionInFlight)
                    }
                }
            }
        }
        .confirmationDialog("Stop this Live Work task?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop task", role: .destructive) { control("stop", ["confirm": true]) }
        }
    }

    private func workstation(inlineBrowser: Bool) -> some View {
        VStack(spacing: 0) {
            header
            if let actionIssue { Text(actionIssue).font(Theme.caption).foregroundStyle(Theme.yellow).padding(8) }
            if let transportIssue { Text(transportIssue).font(Theme.caption).foregroundStyle(Theme.yellow).padding(8) }
            if let state = snapshot {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if inlineBrowser { browser.frame(height: compact ? 430 : 520) }
                        if state.active { running(state) }
                        else {
                            if state.id != nil { running(state) }
                            startForm
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: 810)
                    .frame(maxWidth: .infinity)
                }
            } else if transportIssue == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if inlineBrowser {
                browser
            } else {
                Spacer()
            }
        }
    }

    @Environment(\.compactLayout) private var compact

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("ChatGPT Live Work").font(.headline)
                if let state = snapshot {
                    let ready = state.browser.ok && state.browser.humanCheck != true
                    Label(state.browser.humanCheck == true ? "VPS browser needs verification" :
                          state.browser.ok ? "VPS browser transport online" : "VPS browser unavailable",
                          systemImage: ready ? "dot.radiowaves.left.and.right" : "exclamationmark.triangle")
                        .font(Theme.caption).foregroundStyle(ready ? Theme.green : Theme.yellow)
                }
            }
            Spacer()
            if snapshot != nil || transportIssue != nil {
                Button {
                    if showBrowser {
                        showBrowser = false
                        app.chatBrowser.suspendInput()
                    } else {
                        openBrowser(expanded: false)
                    }
                } label: { Label(showBrowser ? "Hide ChatGPT" : "Open ChatGPT", systemImage: "globe") }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("liveWork.browser")
                Menu {
                    if let state = snapshot, state.browser.ok {
                        Button { openRemoteBrowser(state) } label: { Label("VPS browser fallback", systemImage: "display") }
                    }
                    Button { openURL(conversationLink ?? NativeChatBrowser.home) } label: { Label("Open in Safari", systemImage: "safari") }
                        .disabled(!browserInteractive)
                } label: { Image(systemName: "ellipsis.circle").padding(4) }
                .accessibilityLabel("ChatGPT browser options")
            }
        }
        .padding(12)
        .background(Theme.surface)
        .foregroundStyle(Theme.text)
    }

    private var conversationLink: URL? { NativeChatBrowser.conversation(snapshot?.conversation) }

    private var browserInteractive: Bool {
        guard !actionInFlight else { return false }
        guard let state = snapshot else { return transportIssue != nil }
        return !state.active || (transportIssue == nil && state.nativeControl)
    }

    private var browser: some View {
        let store = app.chatBrowser
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                if store.loading { ProgressView().controlSize(.small) }
                Text("ChatGPT").font(Theme.label)
                Spacer()
                if store.popup != nil {
                    Button("Close sign-in") { store.closePopup() }.font(Theme.caption)
                } else {
                    IconButton(systemName: "arrow.clockwise", help: "Reload conversation") { store.reloadConversation(conversationLink) }
                }
                if !expandBrowser {
                    IconButton(systemName: "arrow.up.left.and.arrow.down.right", help: "Expand ChatGPT") { openBrowser(expanded: true) }
                }
            }.padding(8).background(Theme.surface)
            if let issue = store.issue {
                Text(issue).font(Theme.caption).foregroundStyle(Theme.yellow).padding(8)
            }
            if !browserInteractive {
                HStack {
                    Text(conversationLink == nil ? "Waiting for the VPS to confirm a conversation." : "The VPS is driving this conversation.")
                        .font(Theme.caption).foregroundStyle(Theme.textDim)
                    Spacer()
                    if snapshot?.controllable == true && conversationLink != nil {
                        Button("Take over") { control("takeover", ["nativeBrowser": true]) }
                            .font(Theme.label).disabled(actionInFlight || transportIssue != nil)
                    }
                }.padding(8).background(Theme.raised)
            }
            NativeChatBrowserHost(webView: store.visibleWebView)
                .allowsHitTesting(browserInteractive)
                .accessibilityHidden(!browserInteractive)
                .onChange(of: browserInteractive) { _, granted in if !granted { store.suspendInput() } }
                .accessibilityIdentifier("liveWork.nativeWebView")
        }
        .foregroundStyle(Theme.text)
        .background(Theme.bg)
    }

    private var startForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Live Work task").font(.headline)
            ProjectPicker(selection: Binding(get: { app.studioProject }, set: { app.studioProject = $0 }))
            TextField("What should ChatGPT work on?", text: Binding(get: { request }, set: {
                request = $0
                requestId = UUID().uuidString
            }), axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("liveWork.request")
            Button {
                guard let project = app.studioProject else { return }
                perform {
                    let state = try await app.client.send("POST", endpoint + "/start",
                        ["project": project, "requestId": requestId, "text": request], as: LiveWorkSnapshot.self, timeout: 120)
                    guard state.id != nil else { return state }
                    request = ""
                    requestId = UUID().uuidString
                    openBrowser(expanded: false, link: NativeChatBrowser.conversation(state.conversation))
                    return state
                }
            } label: { Label("Start Live Work", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent)
                .disabled(actionInFlight || transportIssue != nil || snapshot?.browser.ok != true || snapshot?.browser.humanCheck == true || app.studioProject == nil ||
                          request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("liveWork.start")
            if let state = snapshot, state.browser.humanCheck == true || !state.browser.ok,
               let message = state.browser.message { Text(message).font(Theme.caption) }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func running(_ state: LiveWorkSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(state.title ?? "Live Work").font(.headline)
            Text(state.activity ?? state.state).font(Theme.caption).foregroundStyle(Theme.textDim)
            if let error = state.issue { Text(error).font(Theme.caption).foregroundStyle(Theme.yellow) }
            if let pending = state.pending {
                VStack(alignment: .leading, spacing: 8) {
                    Label(pending.verification ? "Review verification" : "Command needs review", systemImage: "hand.raised")
                        .font(Theme.label)
                    code(pending.command)
                    HStack {
                        Button("Review and run") { commandDecision = CommandDecision(command: pending, action: "approve") }
                        Button("Reject", role: .destructive) { commandDecision = CommandDecision(command: pending, action: "reject") }
                    }.buttonStyle(.bordered).disabled(actionInFlight)
                }
                .padding(10).background(Theme.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            }
            if state.controllable {
                if state.active { controls(state) }
                Picker("Live Work evidence", selection: $selectedContent) {
                    Text("Conversation").tag("conversation")
                    Text("Terminal").tag("terminal")
                }.pickerStyle(.segmented)
                if selectedContent == "terminal" { terminalEvidence(state) }
                else { conversation(state) }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(Theme.text)
    }

    private func controls(_ state: LiveWorkSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    if state.canResume { Button("Resume") { desktop.setControl(false); control("resume") } }
                    else { Button("Pause") { control("pause") } }
                    if state.canReattach || state.shell == "disconnected" {
                        Button("Reconnect terminal") { control("reattach") }
                    }
                    if state.canInterrupt { Button("Interrupt command", role: .destructive) { control("interrupt") } }
                    Button("Stop", role: .destructive) { confirmStop = true }
                }.buttonStyle(.bordered)
            }
            if state.canMessage && !state.nativeControl {
                HStack {
                    TextField("Send guidance to ChatGPT", text: Binding(get: { guidance }, set: {
                        guidance = $0
                        guidanceId = UUID().uuidString
                    }), axis: .vertical)
                        .lineLimit(1...4).textFieldStyle(.roundedBorder)
                    Button("Send") {
                        control("message", ["text": guidance, "requestId": guidanceId], sent: true)
                    }.disabled(guidance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }.disabled(actionInFlight)
    }

    private func conversation(_ state: LiveWorkSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let task = state.request { Label("You", systemImage: "person"); Text(task).textSelection(.enabled) }
            if let reply = state.assistant, !reply.isEmpty {
                Label("ChatGPT", systemImage: "sparkle")
                Text((try? AttributedString(markdown: reply, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(reply))
                    .textSelection(.enabled)
            }
            if state.streaming { Label("ChatGPT is writing", systemImage: "ellipsis.bubble").foregroundStyle(Theme.textDim) }
            if let check = state.verification {
                DisclosureGroup("Final verification · \((state.verificationState ?? "pending").replacingOccurrences(of: "_", with: " "))") {
                    code(check)
                }.font(Theme.caption)
            }
        }.font(.callout)
    }

    private func terminalEvidence(_ state: LiveWorkSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if let running = state.current { Label(running.command, systemImage: "terminal") }
            if state.active && !terminal.isEmpty { code(terminal) }
            ForEach(state.commands.reversed()) { item in
                DisclosureGroup {
                    if let output = item.output, !output.isEmpty { code(output) }
                    if item.sent { Text("Result returned to ChatGPT").font(Theme.caption).foregroundStyle(Theme.green) }
                } label: {
                    VStack(alignment: .leading) {
                        Text(item.command ?? "Command").font(.caption.monospaced()).lineLimit(2)
                        if item.refused { Text("Refused").font(Theme.caption).foregroundStyle(Theme.yellow) }
                        else { Text(item.exitCode.map { "Exit \($0)" } ?? "Exit unknown").font(Theme.caption).foregroundStyle(Theme.textDim) }
                    }
                }
            }
        }
    }

    private func code(_ text: String) -> some View {
        ScrollView(.horizontal) {
            Text(text).font(.caption.monospaced()).textSelection(.enabled).padding(8)
        }
        .frame(maxHeight: 240)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 7))
    }

    private func poll() async {
        let client = app.client
        while !Task.isCancelled {
            do {
                let state = try await client.get(endpoint, as: LiveWorkSnapshot.self, timeout: 6)
                guard !Task.isCancelled else { return }
                snapshot = state
                transportIssue = nil
                if showBrowser { app.chatBrowser.follow(NativeChatBrowser.conversation(state.conversation)) }
                if selectedContent == "terminal" && state.active && state.controllable {
                    let tail = try? await client.get(endpoint + "/terminal", as: LiveWorkTerminalTail.self, timeout: 6)
                    if !Task.isCancelled { terminal = tail?.text ?? "" }
                }
            } catch let error as GatewayError where error.status == 404 || error.status == 403 {
                if !Task.isCancelled { transportIssue = "Live Work is available on the paired Musa Studios VPS." }
            } catch {
                if !Task.isCancelled { transportIssue = error.localizedDescription }
            }
            try? await Task.sleep(for: .seconds(transportIssue == nil ? 2 : 7))
        }
    }

    private func openBrowser(expanded: Bool, link: URL? = nil) {
        app.chatBrowser.follow(link ?? conversationLink)
        showBrowser = true
        if expanded { expandBrowser = true }
    }

    private func openRemoteBrowser(_ state: LiveWorkSnapshot) {
        desktop.open(client: app.client, machine: app.activeMachine?.id, display: state.browser.display, presentation: .full)
        desktop.setControl(false)
        expandBrowser = false
        app.showFullScreenDesktop = true
        if state.controllable || state.browser.humanCheck == true {
            Task { _ = try? await app.client.send("POST", endpoint + "/focus", as: LiveWorkSnapshot.self) }
        }
    }

    private func control(_ action: String, _ fields: [String: Any] = [:], sent: Bool = false) {
        guard let id = snapshot?.id else { return }
        var payload = fields
        payload["action"] = action
        payload["jobId"] = id
        perform {
            let state = try await app.client.send("POST", endpoint + "/control", payload, as: LiveWorkSnapshot.self, timeout: 120)
            if sent { guidance = ""; guidanceId = UUID().uuidString }
            return state
        }
    }

    private func perform(_ work: @escaping () async throws -> LiveWorkSnapshot) {
        guard !actionInFlight else { return }
        actionInFlight = true
        actionIssue = nil
        let machine = app.activeMachine?.id
        Task {
            defer { actionInFlight = false }
            do {
                let state = try await work()
                if app.activeMachine?.id == machine { snapshot = state }
            } catch {
                if app.activeMachine?.id == machine { actionIssue = error.localizedDescription }
            }
        }
    }
}
