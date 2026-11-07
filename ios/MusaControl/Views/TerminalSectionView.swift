import SwiftUI
import SwiftTerm

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

/// A terminal with its connection state; used by the Terminal section and workspace panels.
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
                    Text(session.tmuxName).font(.system(size: 10)).foregroundStyle(Theme.textFaint)
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
                            Button("Open SSH settings") { app.go(.settings) }
                            Button("Retry") { session.reconnectNow() }
                        }.font(Theme.label)
                    }
                    .padding(20).background(Theme.raised, in: RoundedRectangle(cornerRadius: 12))
                case .connecting:
                    ProgressView("Connecting to \(SSHSettings.stored?.host ?? "server")…").padding(14).background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
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

struct TerminalSectionView: View {
    @Environment(AppModel.self) private var app
    @Environment(TerminalStore.self) private var store
    @State private var tmuxSessions: [TmuxSession] = []

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            if store.sessions.isEmpty {
                VStack(spacing: 16) {
                    EmptyNote(icon: "terminal", text: "No terminal open", detail: "Every tab is a real SSH session attached to a tmux session on the server, so work keeps running if the iPad disconnects.")
                    HStack {
                        Button { store.newShell() } label: { Label("New shell", systemImage: "plus").padding(.horizontal, 14).frame(height: 36).background(Theme.accent, in: RoundedRectangle(cornerRadius: 8)).foregroundStyle(.black) }.buttonStyle(.plain)
                        attachMenu
                    }
                    Spacer()
                }
            } else {
                HStack(spacing: 1) {
                    if let s = store.current { TerminalPane(session: s, showHeader: store.splitWith != nil).id(s.id) }
                    if let split = store.splitWith, let s2 = store.sessions.first(where: { $0.id == split }), s2.id != store.selected {
                        TerminalPane(session: s2, showHeader: true).id(s2.id)
                    }
                }
                .background(Theme.line)
                keyBar
            }
        }
        .background(Theme.bg)
        .task {
            tmuxSessions = (try? await app.client.get("/api/tmux", as: TmuxList.self).sessions) ?? []
            if let t = app.pendingTerminalAttach { store.open(tmux: t); app.pendingTerminalAttach = nil }
            store.current?.open()
        }
        .onChange(of: app.pendingTerminalAttach) { _, t in if let t { store.open(tmux: t); app.pendingTerminalAttach = nil } }
    }

    var tabBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(store.sessions) { s in
                        HStack(spacing: 6) {
                            StatusDot(status: s.state == .connected ? "idle" : s.state == .closed ? "other" : "approval", size: 6)
                            Text(s.title).font(.system(size: 12, weight: store.selected == s.id ? .semibold : .regular)).lineLimit(1)
                            Button { store.close(s) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 18, height: 18) }.buttonStyle(.plain).foregroundStyle(Theme.textFaint)
                        }
                        .padding(.leading, 10).padding(.trailing, 4).frame(height: 30)
                        .background(store.selected == s.id ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                        .onTapGesture { store.selected = s.id; s.open() }
                        .contextMenu {
                            Button { store.splitWith = s.id } label: { Label("Show beside current", systemImage: "rectangle.split.2x1") }
                            Button { s.reconnectNow() } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
                            Button { store.close(s) } label: { Label("Close tab (tmux keeps running)", systemImage: "xmark") }
                        }
                    }
                }
                .padding(4)
            }
            Spacer(minLength: 0)
            attachMenu
            IconButton(systemName: store.splitWith == nil ? "rectangle.split.2x1" : "rectangle", help: "Split (⌘D)") {
                if store.splitWith == nil { store.splitWith = store.sessions.first { $0.id != store.selected }?.id } else { store.splitWith = nil }
            }
            IconButton(systemName: "textformat.size.smaller", help: "Smaller text") { store.setFontSize(max(9, store.fontSize - 1)) }
            IconButton(systemName: "textformat.size.larger", help: "Larger text") { store.setFontSize(min(24, store.fontSize + 1)) }
            IconButton(systemName: "plus", help: "New shell (⌘T)") { store.newShell() }
        }
        .padding(.trailing, 6).background(Theme.raised)
    }

    var attachMenu: some View {
        Menu {
            SwiftUI.Section("tmux sessions on the server") {
                ForEach(tmuxSessions) { t in
                    Button { store.open(tmux: t.name) } label: { Label("\(t.name)  ·  \(t.windows) window\(t.windows == 1 ? "" : "s")\(t.attached > 0 ? " · attached" : "")", systemImage: "rectangle.on.rectangle") }
                }
            }
            SwiftUI.Section("New shell in project") {
                ForEach(app.projects.prefix(30)) { p in Button { store.newShell(directory: p.path, label: p.name) } label: { Label(p.name, systemImage: p.icon) } }
            }
        } label: { Label("Attach", systemImage: "link").font(Theme.label).padding(.horizontal, 8).frame(height: 30) }
        .task(id: store.sessions.count) { tmuxSessions = (try? await app.client.get("/api/tmux", as: TmuxList.self).sessions) ?? [] }
    }

    /// Touch-friendly keys beyond SwiftTerm's own accessory bar.
    var keyBar: some View {
        HStack(spacing: 4) {
            ForEach([("esc", "\u{1b}"), ("tab", "\t"), ("^C", "\u{03}"), ("^D", "\u{04}"), ("^Z", "\u{1a}"), ("^L", "\u{0c}"), ("^R", "\u{12}"), ("↑", "\u{1b}[A"), ("↓", "\u{1b}[B"), ("←", "\u{1b}[D"), ("→", "\u{1b}[C"), ("tmux ⌃b", "\u{02}"), ("|", "|"), ("~", "~"), ("/", "/")], id: \.0) { k in
                Button(k.0) { store.current?.send(text: k.1) }
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .frame(minWidth: 36).frame(height: 30).background(Theme.raised, in: RoundedRectangle(cornerRadius: 6))
                    .buttonStyle(.plain)
            }
            Spacer()
            Button { if let s = UIPasteboard.general.string { store.current?.send(text: s) } } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                .font(Theme.label).buttonStyle(.plain).padding(.horizontal, 8)
        }
        .padding(6).background(Theme.surface)
    }
}
