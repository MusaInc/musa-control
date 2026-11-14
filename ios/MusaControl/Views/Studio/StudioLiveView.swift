import SwiftUI

/// Live evidence and the agent's own words share one desk. Narration stays
/// mounted while the selected work surface changes underneath it.
struct StudioLiveView: View {
    let d: StudioDirector
    let agent: Agent?
    @Environment(AppModel.self) private var app
    @State private var surface = "work"
    @State private var automatic = true
    @State private var desktopDisplay = "99"

    var body: some View {
        VStack(spacing: 0) {
            narration
            HStack(spacing: 12) {
                Picker("Work surface", selection: Binding(get: { surface }, set: { surface = $0; automatic = false })) {
                    Text("Workspace").tag("work")
                    Text("Browser / game").tag("desktop")
                    Text("Screens").tag("screens")
                    if agent?.project != nil { Text("Preview").tag("preview") }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("studio.surface")
                Toggle("Follow", isOn: $automatic).toggleStyle(.switch).fixedSize()
                    .accessibilityHint("Show the work surface for the agent's latest action")
                Spacer(minLength: 0)
                Label("Live", systemImage: "dot.radiowaves.left.and.right")
                    .font(Theme.caption).foregroundStyle(Theme.green)
            }
            .font(Theme.label).padding(.horizontal, 14).padding(.vertical, 8)
            .background(Theme.surface)
            Group {
                switch surface {
                case "desktop":
                    RemoteDesktopPanel(initialDisplay: desktopDisplay).id(desktopDisplay)
                case "screens": LightboxPane(photos: d.photos)
                case "preview":
                    if let project = agent?.project { PreviewPanel(projectId: project) }
                default: StudioStage(director: d, agent: agent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: d.currentEvent?.stableId) { _, _ in follow() }
        .onChange(of: automatic) { _, enabled in if enabled { follow() } }
        .onAppear { follow() }
    }

    var narration: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: d.currentEvent?.icon ?? "scope").foregroundStyle(agent?.tint ?? Theme.accent)
                Text(action).font(.system(size: 14, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Spacer(minLength: 0)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let context = d.currentEvent?.detail?["command"]?.string ?? d.currentEvent?.detail?["path"]?.string {
                        Text(context).font(Theme.monoSmall).foregroundStyle(Theme.textDim)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    if let query = searchQuery {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "magnifyingglass").foregroundStyle(Theme.blue)
                                .symbolEffect(.pulse, options: .repeating)
                            Text(query).font(Theme.monoSmall).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                    DisclosureGroup("Task") {
                        Text(agent?.lastPrompt ?? agent?.title ?? "Agent session")
                            .font(Theme.caption).textSelection(.enabled)
                    }.font(Theme.caption)
                Text(d.narration.isEmpty ? (agent?.lastMessage ?? "The agent's next progress update will stay here.") : d.narration)
                    .font(.system(size: 15)).lineSpacing(4).foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            .frame(maxHeight: 160)
            .accessibilityIdentifier("studio.narration")
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .overlay(alignment: .leading) { Rectangle().fill(agent?.tint ?? Theme.accent).frame(width: 3) }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    var searchQuery: String? {
        guard let e = d.currentEvent, e.kind == "agent.tool",
              let tool = e.detail?["tool"]?.string,
              tool.range(of: "grep|glob|search|list_directory", options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        guard let input = e.detail?["input"]?.string else { return e.title }
        if let data = input.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return value["pattern"] as? String ?? value["query"] as? String ?? value["path"] as? String ?? input
        }
        return input
    }

    var action: String {
        guard let e = d.currentEvent else { return "Waiting for activity" }
        switch e.kind {
        case "agent.command": return "Running a command"
        case "agent.command_done": return "Command finished"
        case "agent.command_failed": return "Command failed"
        case "agent.test": return "Running tests"
        case "agent.read": return "Reading a file"
        case "agent.edit": return "Editing a file"
        case "agent.message": return "Progress update"
        case "agent.prompt": return "Following your instruction"
        case "agent.tool": return e.detail?["tool"]?.string ?? "Using a tool"
        case "agent.image": return "Viewing a screenshot"
        case "agent.done": return "Turn finished"
        default: return e.title
        }
    }

    func follow() {
        guard automatic, let e = d.currentEvent else { return }
        let command = e.detail?["command"]?.string ?? ""
        let tool = e.detail?["tool"]?.string ?? ""
        if e.follow?["view"]?.string == "vnc" || tool.range(of: "browser|playwright|computer|chrome|cdp", options: .regularExpression) != nil {
            surface = "desktop"
        } else if command.range(of: "DISPLAY=:[0-9]+", options: .regularExpression) != nil,
                  let r = command.range(of: "DISPLAY=:[0-9]+", options: .regularExpression) {
            desktopDisplay = String(command[r].dropFirst(9))
            surface = "desktop"
        } else if e.kind == "agent.image" {
            surface = "screens"
        } else if ["agent.read", "agent.edit", "agent.test", "agent.command", "agent.command_done", "agent.command_failed"].contains(e.kind) {
            surface = "work"
        }
    }
}
