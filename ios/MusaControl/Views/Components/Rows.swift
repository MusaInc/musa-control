import SwiftUI

struct AgentRow: View {
    let agent: Agent
    var compact = false
    @Environment(AppModel.self) private var app
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: agent.icon).font(.system(size: 14, weight: .medium))
                    .frame(width: 28, height: 28).background(Theme.hover, in: RoundedRectangle(cornerRadius: 7))
                    .foregroundStyle(agent.agent == "claude" ? Theme.accent : Theme.blue)
                StatusDot(status: agent.status, size: 8).offset(x: 3, y: 3)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent.title).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Text(Fmt.ago(agent.lastActivity)).font(Theme.caption).foregroundStyle(Theme.textFaint)
                }
                HStack(spacing: 6) {
                    Text(agent.agentName).foregroundStyle(Theme.textDim)
                    if let p = app.project(agent.project) { Text("·"); Text(p.name).foregroundStyle(Theme.textDim) }
                    if agent.controllable { Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(Theme.textFaint).help("Running in tmux: controllable") }
                }
                .font(Theme.caption).foregroundStyle(Theme.textFaint)
                if !compact {
                    Text(agent.status == "approval" ? (agent.approval?.question ?? agent.statusText) : (agent.lastEvent?.title ?? agent.statusText))
                        .font(Theme.caption).foregroundStyle(agent.status == "approval" ? Theme.yellow : Theme.textDim).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 6).contentShape(Rectangle())
    }
}

struct EventRow: View {
    let event: TimelineEvent
    var showProject = true
    @Environment(AppModel.self) private var app
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: event.icon).font(.system(size: 12)).foregroundStyle(event.tint == "other" ? Theme.textFaint : Theme.status(event.tint)).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title).font(.system(size: 13.5)).foregroundStyle(Theme.text).lineLimit(2)
                HStack(spacing: 5) {
                    Text(Fmt.time(event.ts))
                    if showProject, let p = app.project(event.project) { Text("·"); Text(p.name) }
                    if let a = event.detail?["agent"]?.string { Text("·"); Text(a == "claude" ? "Claude Code" : "Codex") }
                }
                .font(.system(size: 12)).foregroundStyle(Theme.textFaint)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4).contentShape(Rectangle())
    }
}

/// Native approval UI for an agent's on-screen prompt. Choosing an option
/// presses the same keys a person at the terminal would.
struct ApprovalCard: View {
    let agent: Agent
    let prompt: ApprovalPrompt
    @Environment(AppModel.self) private var app
    @State private var busy: Int?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill").foregroundStyle(Theme.yellow)
                Text("\(agent.agentName) needs your approval").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.yellow)
                Spacer()
                Pill(text: prompt.kind, color: Theme.yellow)
            }
            Text(prompt.question).font(.system(size: 15.5, weight: .semibold)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
            if let cmd = prompt.command {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(cmd).font(Theme.mono).foregroundStyle(Theme.text).padding(10).textSelection(.enabled)
                }
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8))
            }
            DisclosureGroup("What the agent's screen shows") {
                ScrollView { Text(prompt.context).font(Theme.monoSmall).foregroundStyle(Theme.textDim).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(maxHeight: 180)
            }
            .font(Theme.caption).foregroundStyle(Theme.textDim)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { ForEach(prompt.options) { o in optionButton(o) } }
                VStack(spacing: 6) { ForEach(prompt.options) { o in optionButton(o) } }
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(Theme.caption).foregroundStyle(Theme.red) }
        }
        .padding(14)
        .background(Theme.yellow.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.yellow.opacity(0.4)))
        .accessibilityElement(children: .contain)
    }

    func optionButton(_ o: ApprovalOption) -> some View {
        Button { answer(o) } label: {
            HStack(spacing: 6) {
                if busy == o.index { ProgressView().controlSize(.small) }
                Text(o.label).font(.system(size: 14, weight: o.tone == "allow" && o.index == firstAllow ? .semibold : .regular)).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 40)
            .background(bg(o), in: RoundedRectangle(cornerRadius: 9))
            .foregroundStyle(o.tone == "deny" ? Theme.red : o.tone == "allow" && o.index == firstAllow ? Theme.green : Theme.text)
        }
        .buttonStyle(.plain).disabled(busy != nil)
        .accessibilityIdentifier("approval.option.\(o.index)")
    }
    var firstAllow: Int { prompt.options.first { $0.tone == "allow" }?.index ?? -1 }

    func bg(_ o: ApprovalOption) -> Color { o.tone == "allow" && o.index == firstAllow ? Theme.green.opacity(0.14) : o.tone == "deny" ? Theme.red.opacity(0.09) : Theme.raised }

    func answer(_ o: ApprovalOption) {
        busy = o.index; error = nil
        Task {
            defer { busy = nil }
            do {
                _ = try await app.client.send("POST", "/api/agents/\(agent.id.pathSegment)/approval", ["signature": prompt.signature, "option": o.index], as: [String: JSONValue].self)
                Device.notify(.success)
                await app.refreshAgents()
            } catch { self.error = error.localizedDescription; Device.notify(.error); await app.refreshAgents() }
        }
    }
}

/// Panel title bar used inside workspaces and sections.
struct PanelHeader<Trailing: View>: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textDim)
            Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            if let subtitle { Text(subtitle).font(Theme.caption).foregroundStyle(Theme.textFaint).lineLimit(1).truncationMode(.middle) }
            Spacer(minLength: 4)
            trailing()
        }
        .padding(.leading, 12).padding(.trailing, 4).frame(height: 40)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

extension PanelHeader where Trailing == EmptyView {
    init(icon: String, title: String, subtitle: String? = nil) { self.init(icon: icon, title: title, subtitle: subtitle, trailing: { EmptyView() }) }
}

/// Project picker used by section views.
struct ProjectPicker: View {
    @Environment(AppModel.self) private var app
    @Binding var selection: String?
    var body: some View {
        Menu {
            ForEach(app.projects) { p in Button { selection = p.id } label: { Label(p.name, systemImage: p.icon) } }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: app.project(selection)?.icon ?? "folder")
                Text(app.project(selection)?.name ?? "Choose project").lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10.5))
            }
            .font(Theme.label).foregroundStyle(Theme.text)
            .padding(.horizontal, 10).frame(height: 30).background(Theme.raised, in: RoundedRectangle(cornerRadius: 7))
        }
        .accessibilityIdentifier("projectPicker")
    }
}
