import Foundation
import UIKit
import Observation
import SwiftTerm
import Citadel
import NIOCore
import NIOSSH
import CryptoKit

/// Verifies the server's host key against fingerprints pinned from the
/// gateway. A mismatch refuses the connection.
final class PinnedHostKeyValidator: NIOSSHClientServerAuthenticationDelegate {
    let pins: Set<String>
    private(set) var seen: String?
    init(pins: [String]) { self.pins = Set(pins) }
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let line = String(openSSHPublicKey: hostKey)
        let fp = SSHKeys.fingerprint(openSSH: line) ?? "?"
        seen = fp
        if pins.contains(fp) { validationCompletePromise.succeed(()) }
        else { validationCompletePromise.fail(SSHFailure.hostKeyMismatch(fp)) }
    }
}

enum SSHFailure: LocalizedError {
    case notConfigured, hostKeyMismatch(String), closed
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "SSH isn't set up yet. Open Settings → SSH and install this \(Device.name)'s key."
        case .hostKeyMismatch(let fp): return "The server's SSH host key (\(fp)) doesn't match the pinned key. Connection refused."
        case .closed: return "Connection closed"
        }
    }
}

/// One terminal tab: a real SSH PTY attached to a named tmux session, so
/// closing the tab or losing the network never kills the remote work. The
/// SwiftTerm view lives here (not in SwiftUI) so scrollback survives tab and
/// layout changes.
@MainActor
@Observable
final class TerminalSession: NSObject, Identifiable, TerminalViewDelegate {
    enum State: Equatable { case idle, connecting, connected, reconnecting(Int, String), failed(String), closed }
    let id = UUID()
    let tmuxName: String
    let directory: String?
    var title: String
    var state: State = .idle
    var lastLatencyMs: Int?
    @ObservationIgnored let view: SwiftTerm.TerminalView
    @ObservationIgnored private var client: SSHClient?
    @ObservationIgnored private var writer: TTYStdinWriter?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var wantOpen = false
    @ObservationIgnored private var size = (cols: 120, rows: 36)

    init(tmuxName: String, title: String? = nil, directory: String? = nil, fontSize: CGFloat = 13) {
        self.tmuxName = tmuxName
        self.title = title ?? tmuxName
        self.directory = directory
        self.view = SwiftTerm.TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        super.init()
        view.terminalDelegate = self
        view.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        view.nativeBackgroundColor = Theme.terminalBg
        view.nativeForegroundColor = Theme.terminalFg
        view.backgroundColor = view.nativeBackgroundColor
    }

    func setFontSize(_ s: CGFloat) { view.font = UIFont.monospacedSystemFont(ofSize: s, weight: .regular) }

    func open() {
        wantOpen = true
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    /// Detach: the tmux session keeps running on the server.
    func close() {
        wantOpen = false
        task?.cancel(); task = nil
        let c = client; client = nil; writer = nil
        Task { try? await c?.close() }
        state = .closed
    }

    func reconnectNow() { close(); open() }

    private func run() async {
        var attempt = 0
        while wantOpen && !Task.isCancelled {
            state = attempt == 0 ? .connecting : .reconnecting(attempt, lastError ?? "")
            do {
                try await connectOnce()
                attempt = 0
            } catch {
                lastError = error.localizedDescription
                if case SSHFailure.hostKeyMismatch = error { state = .failed(error.localizedDescription); wantOpen = false; break }
                if case SSHFailure.notConfigured = error { state = .failed(error.localizedDescription); wantOpen = false; break }
            }
            guard wantOpen && !Task.isCancelled else { break }
            attempt += 1
            let delay = min(20.0, 0.7 * pow(2.0, Double(min(attempt, 5))))
            state = .reconnecting(attempt, lastError ?? "Connection lost")
            view.feed(text: "\r\n\u{1b}[2m[connection lost — reconnecting in \(Int(delay)) s; your tmux session keeps running]\u{1b}[0m\r\n")
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        task = nil
    }
    @ObservationIgnored private var lastError: String?

    private func connectOnce() async throws {
        guard let s = SSHSettings.stored, s.keyInstalled, !s.pinnedFingerprints.isEmpty else { throw SSHFailure.notConfigured }
        let t0 = Date()
        let validator = PinnedHostKeyValidator(pins: s.pinnedFingerprints)
        let c = try await SSHClient.connect(
            host: s.host, port: s.port,
            authenticationMethod: .ed25519(username: s.user, privateKey: SSHKeys.privateKey()),
            hostKeyValidator: .custom(validator),
            reconnect: .never)
        lastLatencyMs = Int(Date().timeIntervalSince(t0) * 1000)
        client = c
        state = .connected
        let req = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true, term: "xterm-256color",
            terminalCharacterWidth: size.cols, terminalRowHeight: size.rows,
            terminalPixelWidth: 0, terminalPixelHeight: 0,
            terminalModes: .init([.ECHO: 1]))
        // Values captured up front: the PTY closure runs off the main actor.
        let cols = size.cols, rows = size.rows
        let dir = directory.map { " -c " + Self.shellQuote($0) } ?? ""
        let cmd = "stty -echo; exec tmux new-session -A -s \(Self.shellQuote(tmuxName))\(dir)\r"
        let term = view
        try await c.withPTY(req) { [weak self] inbound, outbound in
            await MainActor.run { self?.writer = outbound }
            // Attach (or create) the persistent tmux session, replacing the login shell.
            try await outbound.write(ByteBuffer(string: cmd))
            try? await outbound.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
            for try await chunk in inbound {
                switch chunk {
                case .stdout(let buf), .stderr(let buf):
                    let bytes = Array(buf.readableBytesView)
                    await MainActor.run { term.feed(byteArray: bytes[...]) }
                }
            }
        }
        writer = nil
        try? await c.close()
        client = nil
        throw SSHFailure.closed
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Type text into the terminal (e.g. from a snippet or a paste button).
    func send(text: String) { send(bytes: Array(text.utf8)) }

    private func send(bytes: [UInt8]) {
        guard let writer else { return }
        Task { try? await writer.write(ByteBuffer(bytes: bytes)) }
    }

    // MARK: TerminalViewDelegate

    nonisolated func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        Task { @MainActor in self.send(bytes: bytes) }
    }
    nonisolated func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        Task { @MainActor in
            self.size = (newCols, newRows)
            if let w = self.writer { Task { try? await w.changeSize(cols: newCols, rows: newRows, pixelWidth: 0, pixelHeight: 0) } }
        }
    }
    nonisolated func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {
        Task { @MainActor in if !title.isEmpty { self.title = title } }
    }
    nonisolated func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    nonisolated func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
    nonisolated func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { Task { @MainActor in await UIApplication.shared.open(url) } }
    }
    nonisolated func bell(source: SwiftTerm.TerminalView) {}
    nonisolated func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
        if let s = String(data: content, encoding: .utf8) { Task { @MainActor in UIPasteboard.general.string = s } }
    }
    nonisolated func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
    nonisolated func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
}

/// All open terminal tabs, restored on launch (tmux names persist).
@MainActor
@Observable
final class TerminalStore {
    static let shared = TerminalStore()
    var sessions: [TerminalSession] = []
    var selected: UUID?
    var splitWith: UUID?
    var fontSize: CGFloat = CGFloat(UserDefaults.standard.object(forKey: "terminalFontSize") as? Double ?? 13)

    /// Terminals owned by workspace panels. Not tabs, not persisted as tabs,
    /// and disconnected when their panel goes away (the tmux session stays).
    /// Earlier builds added every panel terminal to the saved tabs and
    /// reconnected all of them on each foreground, leaking SSH connections.
    @ObservationIgnored private var panelSessions: [String: TerminalSession] = [:]

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: "terminalTabs") ?? []
        let tabs = saved.filter { !$0.hasPrefix("mc-ws-") }
        for name in tabs { sessions.append(TerminalSession(tmuxName: name, fontSize: fontSize)) }
        if tabs.count != saved.count { UserDefaults.standard.set(tabs, forKey: "terminalTabs") }
        selected = sessions.first?.id
    }

    func panelSession(_ name: String, title: String?, directory: String?) -> TerminalSession {
        if let s = sessions.first(where: { $0.tmuxName == name }) { return s }
        if let s = panelSessions[name] { return s }
        let s = TerminalSession(tmuxName: name, title: title, directory: directory, fontSize: fontSize)
        panelSessions[name] = s
        return s
    }

    func releasePanel(_ name: String) {
        guard let s = panelSessions[name], s.view.window == nil else { return }
        s.close()
    }

    /// Background: detach everything (tmux keeps the work running).
    func suspendAll() { (sessions + Array(panelSessions.values)).forEach { if $0.state != .closed && $0.state != .idle { $0.close() } } }
    /// Foreground: reconnect only terminals that are actually on screen; the
    /// rest reconnect when shown (TerminalPane.onAppear).
    func resumeVisible() { (sessions + Array(panelSessions.values)).forEach { if $0.view.window != nil { $0.open() } } }

    func persist() { UserDefaults.standard.set(sessions.map(\.tmuxName), forKey: "terminalTabs") }

    @discardableResult
    func open(tmux: String, title: String? = nil, directory: String? = nil) -> TerminalSession {
        if let s = sessions.first(where: { $0.tmuxName == tmux }) { selected = s.id; s.open(); return s }
        let s = TerminalSession(tmuxName: tmux, title: title, directory: directory, fontSize: fontSize)
        sessions.append(s); selected = s.id; persist(); s.open()
        return s
    }

    func newShell(directory: String? = nil, label: String? = nil) {
        var n = 1
        while sessions.contains(where: { $0.tmuxName == "mc-term-\(n)" }) { n += 1 }
        open(tmux: "mc-term-\(n)", title: label ?? "shell \(n)", directory: directory)
    }

    func close(_ s: TerminalSession) {
        s.close()
        sessions.removeAll { $0.id == s.id }
        if selected == s.id { selected = sessions.last?.id }
        if splitWith == s.id { splitWith = nil }
        persist()
    }

    func setFontSize(_ v: CGFloat) {
        fontSize = v; UserDefaults.standard.set(Double(v), forKey: "terminalFontSize")
        (sessions + Array(panelSessions.values)).forEach { $0.setFontSize(v) }
    }

    var current: TerminalSession? { sessions.first { $0.id == selected } }
}
