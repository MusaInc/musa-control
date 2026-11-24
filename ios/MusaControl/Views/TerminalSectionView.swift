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
                            if app.activeMachine?.usesSocketTerminal != true { Button("Open SSH settings") { app.sheet = .settings } }
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
