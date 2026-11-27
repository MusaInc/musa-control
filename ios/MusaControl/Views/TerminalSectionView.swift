import SwiftUI
import SwiftTerm

/// Clean, tabbed tmux-backed terminal section. Each tab attaches to a real
/// remote tmux session over SSH (or WebSocket on hosted/relay machines).
struct TerminalSectionView: View {
    @Environment(AppModel.self) private var app
    @Environment(TerminalStore.self) private var terminals
    @State private var tmuxSessions: [TmuxSession] = []

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            if let current = terminals.current {
                TerminalPane(session: current)
                    .id(current.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    EmptyNote(
                        icon: "terminal",
                        text: "No terminal open",
                        detail: "Start a new persistent tmux shell or attach to a running session on \(app.activeMachine?.name ?? "your machine")."
                    )
                    Button { terminals.newShell(directory: app.project(app.filesProject)?.path) } label: {
                        Label("New shell", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.bg)
        .task { await loadTmux() }
        .onAppear {
            if terminals.sessions.isEmpty && !app.fixtures {
                terminals.newShell(directory: app.project(app.filesProject)?.path)
            }
        }
    }

    var tabBar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(terminals.sessions) { s in
                        let on = terminals.selected == s.id
                        HStack(spacing: 6) {
                            StatusDot(status: dotFor(s.state), size: 6)
                            Text(s.title)
                                .font(.system(size: 12.5, weight: on ? .semibold : .regular))
                                .foregroundStyle(on ? Theme.text : Theme.textDim)
                                .lineLimit(1)
                            Button { terminals.close(s) } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(Theme.textFaint)
                                    .frame(width: 18, height: 18)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Close \(s.title)"))
                        }
                        .padding(.leading, 10)
                        .padding(.trailing, 6)
                        .frame(height: 30)
                        .background(on ? Theme.hover : Theme.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            terminals.selected = s.id
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { _ = s.view.becomeFirstResponder() }
                        }
                    }
                }
                .padding(.vertical, 6)
            }

            Spacer(minLength: 4)

            Menu {
                Button { terminals.newShell() } label: { Label("New shell", systemImage: "plus") }
                if !app.projects.isEmpty {
                    Menu("New shell in project") {
                        ForEach(app.projects) { p in
                            Button { terminals.newShell(directory: p.path, label: p.name) } label: { Label(p.name, systemImage: p.icon) }
                        }
                    }
                }
                if !tmuxSessions.isEmpty {
                    Section("Attach running tmux") {
                        ForEach(tmuxSessions) { t in
                            Button { terminals.open(tmux: t.name) } label: { Label(t.name, systemImage: "terminal") }
                        }
                    }
                }
                Divider()
                Button { Task { await loadTmux() } } label: { Label("Refresh tmux list", systemImage: "arrow.clockwise") }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel(Text("New terminal"))
            .accessibilityIdentifier("terminal.new")
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    func dotFor(_ state: TerminalSession.State) -> String {
        switch state {
        case .connected: return "idle"
        case .connecting, .reconnecting: return "approval"
        case .failed: return "failed"
        default: return "other"
        }
    }

    func loadTmux() async {
        if let list = try? await app.client.get("/api/tmux", as: TmuxList.self) {
            tmuxSessions = list.sessions
        }
    }
}

struct TerminalHost: UIViewRepresentable {
    let session: TerminalSession
    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.backgroundColor = session.view.nativeBackgroundColor
        attach(session.view, to: host)
        return host
    }
    func updateUIView(_ host: UIView, context: Context) {
        if session.view.superview !== host { attach(session.view, to: host) }
    }
    private func attach(_ v: UIView, to host: UIView) {
        v.removeFromSuperview()
        v.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 4),
            v.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            v.topAnchor.constraint(equalTo: host.topAnchor, constant: 2),
            v.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }
}

/// A terminal with its connection state; used by the Terminal section.
struct TerminalPane: View {
    let session: TerminalSession
    var showHeader = false
    @Environment(AppModel.self) private var app
    var body: some View {
        VStack(spacing: 0) {
            if showHeader {
                HStack(spacing: 6) {
                    StatusDot(status: dot, size: 6)
                    Text(session.title).font(Theme.monoSmall).lineLimit(1)
                    Spacer()
                    Text(session.tmuxName).font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
                }
                .padding(.horizontal, 8).frame(height: 24).background(Theme.raised)
            }
            ZStack {
                TerminalHost(session: session)
                switch session.state {
                case .failed(let msg):
                    VStack(spacing: 10) {
                        Image(systemName: "lock.trianglebadge.exclamationmark").font(.system(size: 24)).foregroundStyle(Theme.yellow)
                        Text(msg).font(Theme.label).multilineTextAlignment(.center).frame(maxWidth: 420)
                        HStack {
                            if app.activeMachine?.usesSocketTerminal != true { Button("Open SSH settings") { app.go(.settings) } }
                            Button("Retry") { session.reconnectNow() }
                        }.font(Theme.label)
                    }
                    .padding(20).background(Theme.raised, in: RoundedRectangle(cornerRadius: 12))
                case .connecting:
                    ProgressView("Connecting to \(app.activeMachine?.name ?? "workspace")…").padding(14).background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
                default: EmptyView()
                }
            }
        }
        .onAppear { if session.state == .idle || session.state == .closed { session.open() } }
    }
    var dot: String {
        switch session.state { case .connected: return "idle"; case .connecting, .reconnecting: return "approval"; case .failed: return "failed"; default: return "other" }
    }
}
