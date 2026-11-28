import SwiftUI
import WebKit
import Observation
import UIKit

/// The one Remote Desktop connection. It belongs to the app, not to a
/// screen: the WKWebView (and its VNC WebSocket) is created once and moved
/// between the split, floating, full-screen and mini layouts, so navigating
/// around the workspace never drops the connection.
@MainActor
@Observable
final class DesktopStore: NSObject, WKScriptMessageHandler {
    enum Presentation: String, CaseIterable { case split, floating, full, mini }

    // What's open
    private(set) var active = false
    private(set) var display = UserDefaults.standard.string(forKey: "desktop.display") ?? "99"
    private(set) var control = false
    var presentation: Presentation = Presentation(rawValue: UserDefaults.standard.string(forKey: "desktop.presentation") ?? "") ?? .split {
        didSet { UserDefaults.standard.set(presentation.rawValue, forKey: "desktop.presentation") }
    }
    /// Split: share of the window the desktop takes; the side follows the window shape.
    var splitFraction: CGFloat = CGFloat(UserDefaults.standard.object(forKey: "desktop.split") as? Double ?? 0.45) {
        didSet { UserDefaults.standard.set(Double(splitFraction), forKey: "desktop.split") }
    }
    /// Floating window frame as fractions of the window (survives rotation).
    var floatFrame: CGRect = DesktopStore.loadFloat() {
        didSet { UserDefaults.standard.set([floatFrame.minX, floatFrame.minY, floatFrame.width, floatFrame.height].map { Double($0) }, forKey: "desktop.float") }
    }

    // Live state from the page
    private(set) var connected = false
    private(set) var status = "Not connected"
    private(set) var rtt: Int?
    private(set) var kbps: Int?
    private(set) var size: CGSize?
    private(set) var hasFocus = false
    private(set) var displays: [Display] = []
    private(set) var lastClipboard: String?

    // Controls
    var zoom: Double = 0 { didSet { js("window.mc && mc.zoom && mc.zoom(\(zoom))") } }   // 0 = fit
    var quality: Int = UserDefaults.standard.object(forKey: "desktop.quality") as? Int ?? 6 {
        didSet { UserDefaults.standard.set(quality, forKey: "desktop.quality"); js("window.mc && mc.setQuality(\(quality))") }
    }
    var cmdAsCtrl: Bool = UserDefaults.standard.object(forKey: "desktop.cmdAsCtrl") as? Bool ?? true {
        didSet { UserDefaults.standard.set(cmdAsCtrl, forKey: "desktop.cmdAsCtrl"); js("window.mc && mc.setCmdAsCtrl(\(cmdAsCtrl))") }
    }
    /// Open (or bring forward) the desktop when an agent drives a browser.
    var followAgents: Bool = UserDefaults.standard.object(forKey: "desktop.followAgents") as? Bool ?? true {
        didSet { UserDefaults.standard.set(followAgents, forKey: "desktop.followAgents") }
    }
    var showKeys = false          // on-screen key bar (touch typing, Esc/Tab/arrows/modifiers)
    var rightClickNext = false

    @ObservationIgnored private(set) var webView: DesktopWebView?
    @ObservationIgnored private var client: GatewayClient?
    @ObservationIgnored private var machineId: String?
    @ObservationIgnored private var loadGeneration = UUID()
    @ObservationIgnored private var displayTask: Task<Void, Never>?

    nonisolated static func loadFloat() -> CGRect {
        if let a = UserDefaults.standard.array(forKey: "desktop.float") as? [Double], a.count == 4 { return CGRect(x: a[0], y: a[1], width: a[2], height: a[3]) }
        return CGRect(x: 0.52, y: 0.5, width: 0.44, height: 0.42)
    }

    // MARK: lifecycle

    /// Open (or switch to) a display. Keeps the existing connection when it's
    /// already showing that display.
    func open(client: GatewayClient, machine: String?, display d: String? = nil, presentation p: Presentation? = nil) {
        if let p { presentation = p }
        if machineId != machine { teardown() }
        self.client = client; machineId = machine
        let target = d ?? display
        if active, webView != nil, target == display { return }
        if target != display { control = false }
        display = target
        UserDefaults.standard.set(target, forKey: "desktop.display")
        active = true
        UserDefaults.standard.set(true, forKey: "desktop.active")
        load()
        startDisplayRefresh()
    }

    func close() {
        teardown()
        UserDefaults.standard.set(false, forKey: "desktop.active")
    }

    /// Machine switch / sign-out: drop the connection but keep preferences.
    func teardown() {
        loadGeneration = UUID()
        webView?.evaluateJavaScript("window.mc && mc.disconnect()")
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "mc")
        webView?.removeFromSuperview()
        webView = nil
        displayTask?.cancel(); displayTask = nil
        active = false; connected = false; hasFocus = false; control = false
        status = "Not connected"; rtt = nil; kbps = nil; size = nil
    }

    var wasActive: Bool { UserDefaults.standard.bool(forKey: "desktop.active") }

    private func load() {
        guard let client else { return }
        let w: DesktopWebView
        if let existing = webView { w = existing } else {
            let cfg = WKWebViewConfiguration()
            cfg.websiteDataStore = .default()
            cfg.userContentController.add(WeakHandler(self), name: "mc")
            cfg.allowsInlineMediaPlayback = true
            w = DesktopWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 500), configuration: cfg)
            w.store = self
            w.isOpaque = false
            w.backgroundColor = Theme.terminalBg
            w.scrollView.isScrollEnabled = false
            w.scrollView.contentInsetAdjustmentBehavior = .never
            w.scrollView.bounces = false
            webView = w
        }
        let generation = UUID()
        loadGeneration = generation
        connected = false; status = "Connecting…"
        let url = client.url("/vnc.html", ["display": display, "mode": control ? "control" : "observe", "cmd": cmdAsCtrl ? "ctrl" : "super"])
        Task {
            do {
                try await WebSessionCookie.install(client: client, into: w.configuration.websiteDataStore.httpCookieStore)
                guard loadGeneration == generation, webView === w else { return }
                w.load(URLRequest(url: url))
            } catch {
                if loadGeneration == generation { status = "Couldn't authorise the remote desktop: \(error.localizedDescription)" }
            }
        }
    }

    private func startDisplayRefresh() {
        displayTask?.cancel()
        displayTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshDisplays()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    func refreshDisplays() async {
        guard let client, let d = try? await client.get("/api/vnc/displays", as: [Display].self) else { return }
        displays = d
    }

    var currentDisplay: Display? { displays.first { $0.display == display } }

    // MARK: control

    func setControl(_ on: Bool) {
        control = on
        js("window.mc && mc.setMode('\(on ? "control" : "observe")')")
        if !on { webView?.endEditing(true) }
    }
    func switchDisplay(_ d: String) {
        guard d != display, let client else { return }
        control = false
        open(client: client, machine: machineId, display: d)
    }
    func reconnect() {
        if webView?.url == nil { load() } else { js("window.mc && mc.reconnect()") }
    }
    /// Called when the app returns to the foreground.
    func resume() { if active && !connected { reconnect() } }

    func focusKeyboard() { webView?.becomeFirstResponder(); js("window.mc && mc.focus()") }
    func releaseKeyboard() { js("window.mc && mc.blur()"); webView?.endEditing(true) }

    // Input helpers
    func type(_ text: String) {
        let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8)
        js("window.mc && mc.type(\(String(data: data, encoding: .utf8)!)[0])")
    }
    func pasteFromDevice(shift: Bool = false) {
        guard let s = UIPasteboard.general.string, let data = try? JSONSerialization.data(withJSONObject: [s]) else { return }
        js("window.mc && mc.pasteAndSend(\(String(data: data, encoding: .utf8)!)[0], \(shift))")
    }
    func key(_ keysym: Int) { js("window.mc && mc.key(\(keysym))") }
    func combo(_ keysyms: [Int]) { js("window.mc && mc.combo([\(keysyms.map(String.init).joined(separator: ","))])") }
    func scroll(_ steps: Int) { js("window.mc && mc.scroll(\(steps))") }
    func click(_ button: String) { js("window.mc && mc.click('\(button)')") }

    func js(_ s: String) { webView?.evaluateJavaScript(s) }

    // MARK: page → app

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "connected":
            connected = true; status = "Live"
            if let w = body["width"] as? Double, let h = body["height"] as? Double { size = CGSize(width: w, height: h) }
            js("window.mc && mc.setQuality(\(quality))")
            if zoom != 0 { js("window.mc && mc.zoom && mc.zoom(\(zoom))") }
        case "disconnected": connected = false; status = "Reconnecting…"
        case "stats": rtt = body["rtt"] as? Int; kbps = body["kbps"] as? Int
        case "clipboard":
            // Remote → iPad clipboard (what you copy over there pastes here).
            if let t = body["text"] as? String, !t.isEmpty { UIPasteboard.general.string = t; lastClipboard = t }
        case "focus": hasFocus = body["focused"] as? Bool ?? false
        default: break
        }
    }

    // MARK: physical keyboard (DesktopWebView)

    /// ⌘ shortcuts while the desktop has the keyboard in Control mode go to
    /// the remote as Ctrl shortcuts; ⌘V pastes the iPad clipboard there
    /// first. ⌃⌘ shortcuts and ⌘1–9 stay with Musa Control.
    var interceptsCommandKeys: Bool { active && control && cmdAsCtrl && connected }

    func remoteShortcut(_ input: String, shift: Bool, alt: Bool) {
        let ch = input.lowercased()
        if ch == "v" { pasteFromDevice(shift: shift); return }
        var keys = [0xffe3]
        if shift { keys.append(0xffe1) }
        if alt { keys.append(0xffe9) }
        switch input {
        case UIKeyCommand.inputLeftArrow: combo([0xff50]); return        // ⌘← Home
        case UIKeyCommand.inputRightArrow: combo([0xff57]); return       // ⌘→ End
        case UIKeyCommand.inputUpArrow: combo([0xffe3, 0xff50]); return  // ⌘↑ Ctrl+Home
        case UIKeyCommand.inputDownArrow: combo([0xffe3, 0xff57]); return
        default: break
        }
        guard let scalar = ch.unicodeScalars.first else { return }
        keys.append(Int(scalar.value))
        combo(keys)
    }
}

/// Keeps WKUserContentController from retaining the store forever.
final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ t: any WKScriptMessageHandler) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { target?.userContentController(c, didReceive: m) }
}

/// WKWebView that maps ⌘ shortcuts to the remote session while it has the
/// keyboard. Responder-chain key commands win over the app's menu commands,
/// so ⌘C/⌘V/⌘Z/⌘S/⌘F… reach the remote instead of Musa Control.
final class DesktopWebView: WKWebView {
    weak var store: DesktopStore?
    private static let letters = Array("abcdefghijklmnopqrstuvwxyz/.,;[]-=").map(String.init)

    override var keyCommands: [UIKeyCommand]? {
        guard let store, store.interceptsCommandKeys else { return super.keyCommands }
        var out: [UIKeyCommand] = []
        for l in Self.letters {
            for mods: UIKeyModifierFlags in [.command, [.command, .shift], [.command, .alternate]] {
                let c = UIKeyCommand(input: l, modifierFlags: mods, action: #selector(remoteKey(_:)))
                c.wantsPriorityOverSystemBehavior = true
                out.append(c)
            }
        }
        for a in [UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow, UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow] {
            let c = UIKeyCommand(input: a, modifierFlags: .command, action: #selector(remoteKey(_:)))
            c.wantsPriorityOverSystemBehavior = true
            out.append(c)
        }
        return (super.keyCommands ?? []) + out
    }

    @objc func remoteKey(_ cmd: UIKeyCommand) {
        guard let input = cmd.input else { return }
        let mods = cmd.modifierFlags
        store?.remoteShortcut(input, shift: mods.contains(.shift), alt: mods.contains(.alternate))
    }
}

/// Hosts the store's web view wherever the desktop is currently shown.
/// Moving between layouts re-parents the same view; nothing reconnects.
struct DesktopHost: UIViewRepresentable {
    let store: DesktopStore
    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.backgroundColor = Theme.terminalBg
        host.clipsToBounds = true
        attach(to: host)
        return host
    }
    func updateUIView(_ host: UIView, context: Context) { attach(to: host) }
    private func attach(to host: UIView) {
        guard let w = store.webView, w.superview !== host else { return }
        w.removeFromSuperview()
        w.frame = host.bounds
        w.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(w)
    }
    // Deliberately no dismantle: the connection outlives this host.
}
