import SwiftUI

/// Start Claude Code or Codex in a project. Runs as an interactive session
/// in its own tmux session on the server, with the agent's normal permission
/// prompts — answered from the app's approval cards.
struct AgentLauncher: View {
    let initialProject: String?
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var agent = UserDefaults.standard.string(forKey: "launcher.agent") ?? "claude"
    @State private var project: String?
    @State private var prompt = ""
    @AppStorage("launcher.permissionMode") private var mode = "unattended"
    @State private var busy = false
    @State private var error: String?
    @State private var duplicate: String?
    @State private var errorOutput: String?
    @FocusState private var focus: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("New agent task").font(.system(size: 19, weight: .semibold))
                Spacer()
                IconButton(systemName: "xmark", help: "Close") { dismiss() }
            }
            Picker("Agent", selection: $agent) {
                Label("Claude Code", systemImage: "sparkle").tag("claude")
                Label("Codex", systemImage: "terminal").tag("codex")
            }.pickerStyle(.segmented)
            // The project decides where the agent runs and what it can edit, so
            // it is never chosen silently: the last workspace is only a
            // suggestion and is named on the Start button.
            ViewThatFits(in: .horizontal) {
                HStack { runsIn; Spacer(); permissions }
                VStack(alignment: .leading, spacing: 8) { runsIn; permissions }
            }
            TextField("What should \(agent == "claude" ? "Claude Code" : "Codex") do?", text: $prompt, axis: .vertical)
                .lineLimit(4...12).font(.system(size: 14)).focused($focus)
                .padding(12).background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("launcher.prompt")
            Text("Keeps working when you disconnect. Unattended mode allows commands and edits across this computer without approval prompts.")
                .font(Theme.caption).foregroundStyle(Theme.textFaint)
            if let error {
                VStack(alignment: .leading, spacing: 6) {
                    Label(error, systemImage: "exclamationmark.triangle").font(Theme.caption).foregroundStyle(Theme.red)
                    if let out = errorOutput, !out.isEmpty { LogBox(text: out, maxHeight: 140) }
                }
            }
            if let duplicate {
                ViewThatFits(in: .horizontal) {
                    HStack { duplicateButtons(duplicate) }
                    VStack(alignment: .leading, spacing: 8) { duplicateButtons(duplicate) }
                }.font(Theme.label)
            }
            HStack {
                Spacer()
                Button { launch(allowDuplicate: false) } label: {
                    HStack { if busy { ProgressView().controlSize(.small) }; Text(startLabel).font(.system(size: 14, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8) }
                        .padding(.horizontal, 22).frame(maxWidth: Device.isPhone ? CGFloat.infinity : nil).frame(height: 38).background(project == nil ? Theme.hover : Theme.accent, in: RoundedRectangle(cornerRadius: 9)).foregroundStyle(Theme.onAccent)
                }
                .buttonStyle(.plain).disabled(project == nil || busy).keyboardShortcut(.return, modifiers: .command)
                .accessibilityIdentifier("launcher.start")
            }
        }
        .padding(20).frame(minWidth: Device.isPhone ? nil : 360, idealWidth: 600)
        .frame(maxHeight: Device.isPhone ? CGFloat.infinity : nil, alignment: .top)
        .background(Theme.surface)
        .onAppear { project = initialProject ?? app.workspaceProject; focus = true }
        .onChange(of: agent) { _, a in mode = mode == "unattended" ? "unattended" : "default"; UserDefaults.standard.set(a, forKey: "launcher.agent") }
    }

    var runsIn: some View {
        HStack {
            Text("Runs in").font(Theme.label).foregroundStyle(Theme.textDim)
            ProjectPicker(selection: $project)
        }
    }

    var permissions: some View {
        Picker("Permissions", selection: $mode) {
            Text("Unattended · no approvals").tag("unattended")
            if agent == "claude" {
                Text("Ask before acting").tag("default")
                Text("Auto-accept edits").tag("acceptEdits")
                Text("Plan only").tag("plan")
            } else {
                Text("Workspace write, ask").tag("default")
                Text("Read-only").tag("read-only")
            }
        }.pickerStyle(.menu)
    }

    @ViewBuilder func duplicateButtons(_ id: String) -> some View {
        Button("Open the running session") { app.openAgent(id); dismiss() }
        Button("Start a second one anyway") { launch(allowDuplicate: true) }
    }

    var startLabel: String {
        guard let p = app.project(project) else { return "Choose a project" }
        return "Start \(agent == "claude" ? "Claude Code" : "Codex") in \(p.name)"
    }

    func launch(allowDuplicate: Bool) {
        guard let project else { return }
        busy = true; error = nil; duplicate = nil; errorOutput = nil
        Task {
            defer { busy = false }
            do {
                let r = try await app.client.send("POST", "/api/agents", ["agent": agent, "project": project, "prompt": prompt, "mode": mode, "allowDuplicate": allowDuplicate], as: LaunchResult.self)
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                await app.refreshAgents()
                let target = r.sessionKey.flatMap { k in app.agents.first { $0.id == k } }?.id ?? app.agents.first { $0.tmux?.session == r.tmux }?.id
                if let target { app.openAgent(target) } else { app.go(.agents) }
                dismiss()
            } catch let e as GatewayError where e.isConflict {
                error = e.message
                duplicate = e.decode([String: String].self)?["duplicate"]
            } catch let e as GatewayError {
                self.error = e.message
                errorOutput = e.decode([String: JSONValue].self)?["output"]?.string
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// ⌘K: jump to any project, agent or section.
struct QuickSwitcher: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var q = ""
    @FocusState private var focus: Bool

    struct Item: Identifiable { let id: String; let title: String; let subtitle: String; let icon: String; let run: () -> Void }

    var items: [Item] {
        var out: [Item] = []
        for a in app.agents where a.status != "ended" { out.append(Item(id: "a" + a.id, title: a.title, subtitle: "\(a.agentName) · \(a.statusText)", icon: a.icon) { app.openAgent(a.id) }) }
        for p in app.projects { out.append(Item(id: "p" + p.id, title: p.name, subtitle: "Workspace · \(p.kind)", icon: p.icon) { app.openWorkspace(p.id) }) }
        for s in AppSection.allCases { out.append(Item(id: "s" + s.rawValue, title: s.title, subtitle: "Section", icon: s.icon) { app.go(s) }) }
        guard !q.isEmpty else { return out }
        let needle = q.lowercased()
        return out.filter { $0.title.lowercased().contains(needle) || $0.subtitle.lowercased().contains(needle) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textDim)
                TextField("Jump to project, agent or section", text: $q).font(.system(size: 16)).focused($focus)
                    .onSubmit { if let f = items.first { f.run(); dismiss() } }
            }
            .padding(14).background(Theme.raised)
            List(items.prefix(40)) { i in
                Button { i.run(); dismiss() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: i.icon).frame(width: 20).foregroundStyle(Theme.accent)
                        VStack(alignment: .leading) { Text(i.title).font(.system(size: 14.5)); Text(i.subtitle).font(Theme.caption).foregroundStyle(Theme.textDim) }
                    }
                }.buttonStyle(.plain).listRowBackground(Theme.surface)
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
        }
        .frame(minWidth: Device.isPhone ? nil : 520, minHeight: Device.isPhone ? nil : 440).background(Theme.surface)
        .onAppear { focus = true }
    }
}
