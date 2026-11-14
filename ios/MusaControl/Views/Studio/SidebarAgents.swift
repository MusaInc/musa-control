import SwiftUI

/// Sidebar: every running agent on its own row, showing what it is doing
/// right now. Tapping one opens its live studio.
struct SidebarAgents: View {
    let rail: Bool
    let navigate: (() -> Void) -> Void
    @Environment(AppModel.self) private var app

    var agents: [Agent] {
        let order = ["approval": 0, "working": 1, "idle": 2]
        return app.agents.filter { $0.isLive }
            .sorted { (order[$0.status] ?? 3, -$0.lastActivity) < (order[$1.status] ?? 3, -$1.lastActivity) }
            .prefix(8).map { $0 }
    }

    var body: some View {
        let list = agents
        if rail {
            if !list.isEmpty {
                VStack(spacing: 8) {
                    Rectangle().fill(Theme.line).frame(width: 28, height: 1).padding(.vertical, 6)
                    ForEach(list) { a in
                        Button { navigate { app.openStudio(a.id) } } label: {
                            AgentAvatar(kind: a.agent, status: a.status, size: 30)
                                .padding(4)
                                .background(app.studioAgent == a.id ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .help(a.title)
                        .accessibilityLabel(Text("\(a.agentName): \(a.title)"))
                        .accessibilityIdentifier("sidebar.agent.\(a.id)")
                    }
                }
                .frame(maxWidth: .infinity)
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                SectionHeader(title: "Active agents", trailing: list.isEmpty ? nil : AnyView(
                    Text("\(list.count)").font(.system(size: 11.5, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.textFaint)
                ))
                .padding(.top, 10)
                if list.isEmpty {
                    Text("No agents running").font(Theme.caption).foregroundStyle(Theme.textFaint)
                        .padding(.horizontal, 20).padding(.vertical, 4)
                }
                ForEach(list) { a in
                    SidebarAgentRow(agent: a, selected: app.studioAgent == a.id) { navigate { app.openStudio(a.id) } }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.3), value: list.map(\.id))
        }
    }
}

struct SidebarAgentRow: View {
    let agent: Agent
    let selected: Bool
    let action: () -> Void
    @Environment(AppModel.self) private var app

    static func verb(_ t: String) -> String {
        if t.hasPrefix("$ ") { return "Running " + t.dropFirst(2) }
        if t.hasPrefix("Running tests: ") { return "Running tests" }
        return t
    }

    var taskLabel: String {
        // A short, whole-word label; the complete task is in the studio.
        let text = agent.lastPrompt ?? agent.title
        return text.split(whereSeparator: { $0.isWhitespace }).prefix(10).joined(separator: " ").replacingOccurrences(of: "…", with: "")
    }

    var doing: String {
        switch agent.status {
        case "approval": return "Needs your OK"
        case "idle": return "Waiting for you"
        default:
            let live = app.liveEvents.last { $0.session == agent.id && StudioDirector.isScene($0) }
            switch live?.kind ?? agent.lastEvent?.kind {
            case "agent.edit": return "Editing a file"
            case "agent.read": return "Reading a file"
            case "agent.test": return "Running tests"
            case "agent.command": return "Running a command"
            case "agent.command_done": return "Command finished"
            case "agent.command_failed": return "Command failed"
            case "agent.message": return "Progress updated"
            case "agent.image": return "Viewing a screenshot"
            case "agent.tool": return "Using a tool"
            default: return "Working"
            }
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                AgentAvatar(kind: agent.agent, status: agent.status, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(taskLabel).font(.system(size: 13.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 5) {
                        if agent.status == "working" { TypingDots(color: agent.tint, size: 3.5) }
                        Text(doing)
                            .foregroundStyle(agent.status == "approval" ? Theme.yellow : Theme.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                            .contentTransition(.opacity)
                            .animation(.easeOut(duration: 0.25), value: doing)
                    }
                    .font(.system(size: 11.5))
                    if let p = app.project(agent.project) {
                        Text("\(p.name) · \(agent.shortName)").font(.system(size: 11)).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(selected ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .hoverEffect(.highlight)
        .accessibilityLabel(Text("\(agent.agentName), \(agent.title), \(doing)"))
        .accessibilityIdentifier("sidebar.agent.\(agent.id)")
    }
}
