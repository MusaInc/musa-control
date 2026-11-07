import SwiftUI
import WebKit

/// Gives a WKWebView the gateway's short-lived web-session cookie so pages
/// served under /control (noVNC host, static builds) are authorised.
@MainActor
enum WebSessionCookie {
    private static var issuedAt: Date?
    static func install(client: GatewayClient, into store: WKHTTPCookieStore) async throws {
        if let t = issuedAt, Date().timeIntervalSince(t) < 6 * 3600 { return }
        let s = try await client.send("POST", "/api/web-session", [:], as: WebSession.self)
        var props: [HTTPCookiePropertyKey: Any] = [
            .name: s.cookie.name, .value: s.cookie.value, .domain: client.host, .path: s.cookie.path,
            .secure: "TRUE", .expires: Date().addingTimeInterval(s.cookie.maxAge),
        ]
        props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
        if let c = HTTPCookie(properties: props) { await store.setCookie(c) }
        issuedAt = Date()
    }
    static func reset() { issuedAt = nil }
}

// MARK: - Remote desktop

@MainActor
@Observable
final class VNCController: NSObject, WKScriptMessageHandler {
    var connected = false
    var status = "Connecting…"
    var rtt: Int?
    var kbps: Int?
    var size: CGSize?
    var mode: String
    let display: String
    @ObservationIgnored weak var webView: WKWebView?

    init(display: String, mode: String) { self.display = display; self.mode = mode }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "connected":
            connected = true; status = "Live"
            if let w = body["width"] as? Double, let h = body["height"] as? Double { size = CGSize(width: w, height: h) }
        case "disconnected": connected = false; status = "Reconnecting…"
        case "stats": rtt = body["rtt"] as? Int; kbps = body["kbps"] as? Int
        case "clipboard": if let t = body["text"] as? String { UIPasteboard.general.string = t }
        default: break
        }
    }

    func js(_ s: String) { webView?.evaluateJavaScript(s) }
    func setMode(_ m: String) { mode = m; js("window.mc && mc.setMode('\(m)')") }
    func reconnect() { js("window.mc && mc.reconnect()") }
    func type(_ text: String) {
        let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8)
        js("window.mc && mc.type(\(String(data: data, encoding: .utf8)!)[0])")
    }
    func paste() {
        guard let s = UIPasteboard.general.string, let data = try? JSONSerialization.data(withJSONObject: [s]) else { return }
        js("window.mc && mc.paste(\(String(data: data, encoding: .utf8)!)[0])")
    }
    func key(_ keysym: Int) { js("window.mc && mc.key(\(keysym))") }
}

struct VNCWebView: UIViewRepresentable {
    @Environment(AppModel.self) private var app
    let controller: VNCController

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.userContentController.add(controller, name: "mc")
        cfg.allowsInlineMediaPlayback = true
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.isOpaque = false
        w.backgroundColor = UIColor(red: 0.055, green: 0.059, blue: 0.067, alpha: 1)
        w.scrollView.isScrollEnabled = true
        w.scrollView.minimumZoomScale = 1
        w.scrollView.maximumZoomScale = 6
        w.scrollView.bouncesZoom = true
        w.scrollView.contentInsetAdjustmentBehavior = .never
        controller.webView = w
        let url = app.client.url("/vnc.html", ["display": controller.display, "mode": controller.mode])
        Task {
            do {
                try await WebSessionCookie.install(client: app.client, into: w.configuration.websiteDataStore.httpCookieStore)
                w.load(URLRequest(url: url))
            } catch { controller.status = "Couldn't authorise the remote desktop: \(error.localizedDescription)" }
        }
        return w
    }
    func updateUIView(_ w: WKWebView, context: Context) {}
    static func dismantleUIView(_ w: WKWebView, coordinator: ()) {
        w.evaluateJavaScript("window.mc && mc.disconnect()")
        w.configuration.userContentController.removeScriptMessageHandler(forName: "mc")
    }
}

// MARK: - Live previews

/// Serves mcpreview://<port>/<path> from the gateway's authenticated proxy to
/// a project's local dev server, so absolute asset paths keep working.
final class PreviewSchemeHandler: NSObject, WKURLSchemeHandler {
    let client: GatewayClient
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    var onConsole: ((String) -> Void)?
    init(client: GatewayClient) { self.client = client }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let port = url.host else { task.didFailWithError(URLError(.badURL)); return }
        let path = url.path.isEmpty ? "/" : url.path
        var req = client.request(task.request.httpMethod ?? "GET", "/api/proxy/\(port)\(path.hasPrefix("/") ? path : "/" + path)", timeout: 60)
        if let q = url.query, let u = req.url, var c = URLComponents(url: u, resolvingAgainstBaseURL: false) { c.percentEncodedQuery = q; req.url = c.url }
        req.httpBody = task.request.httpBody
        for (k, v) in task.request.allHTTPHeaderFields ?? [:] where !["Authorization", "Host"].contains(k) { req.setValue(v, forHTTPHeaderField: k) }
        let key = ObjectIdentifier(task)
        tasks[key] = Task {
            do {
                let (data, http) = try await client.transport.send(req)
                var headers = http.allHeaderFields as? [String: String] ?? [:]
                headers.removeValue(forKey: "Content-Encoding"); headers.removeValue(forKey: "content-encoding")
                headers["Content-Length"] = String(data.count)
                let resp = HTTPURLResponse(url: url, statusCode: http.statusCode, httpVersion: "HTTP/1.1", headerFields: headers)!
                await MainActor.run {
                    guard self.tasks[key] != nil else { return }
                    task.didReceive(resp); task.didReceive(data); task.didFinish()
                    self.tasks[key] = nil
                }
            } catch {
                await MainActor.run { if self.tasks[key] != nil { task.didFailWithError(error); self.tasks[key] = nil } }
            }
        }
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) { tasks[ObjectIdentifier(task)]?.cancel(); tasks[ObjectIdentifier(task)] = nil }
}

@MainActor
@Observable
final class PreviewController: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var console: [String] = []
    var loading = false
    var title = ""
    var error: String?
    @ObservationIgnored weak var webView: WKWebView?

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        if let s = message.body as? String { console.append(s); if console.count > 300 { console.removeFirst(console.count - 300) } }
    }
    func reload() { webView?.reload() }
    func webView(_ w: WKWebView, didStartProvisionalNavigation n: WKNavigation!) { loading = true; error = nil }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { loading = false; title = w.title ?? "" }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { loading = false; error = e.localizedDescription }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { loading = false; error = e.localizedDescription }

    func snapshot() async -> UIImage? {
        guard let w = webView else { return nil }
        return try? await w.takeSnapshot(configuration: nil)
    }
}

struct PreviewWebView: UIViewRepresentable {
    @Environment(AppModel.self) private var app
    let url: URL
    let controller: PreviewController
    var needsCookie = false

    static let consoleHook = """
    (function(){ const send = (lvl, args) => { try { window.webkit.messageHandlers.console.postMessage(lvl + ': ' + Array.from(args).map(a => { try { return typeof a === 'string' ? a : JSON.stringify(a) } catch { return String(a) } }).join(' ')) } catch(e){} };
      for (const l of ['log','warn','error','info']) { const o = console[l]; console[l] = function(){ send(l, arguments); o.apply(console, arguments) } }
      window.addEventListener('error', e => send('error', [e.message + ' @ ' + (e.filename||'') + ':' + (e.lineno||'')]));
      window.addEventListener('unhandledrejection', e => send('error', ['Unhandled rejection: ' + (e.reason && e.reason.message || e.reason)])); })();
    """

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(PreviewSchemeHandler(client: app.client), forURLScheme: "mcpreview")
        cfg.userContentController.add(controller, name: "console")
        cfg.userContentController.addUserScript(WKUserScript(source: Self.consoleHook, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.navigationDelegate = controller
        w.isInspectable = true
        w.allowsBackForwardNavigationGestures = true
        controller.webView = w
        load(w)
        return w
    }
    func load(_ w: WKWebView) {
        if needsCookie {
            Task { try? await WebSessionCookie.install(client: app.client, into: w.configuration.websiteDataStore.httpCookieStore); w.load(URLRequest(url: url)) }
        } else { w.load(URLRequest(url: url)) }
    }
    func updateUIView(_ w: WKWebView, context: Context) {
        if w.url?.absoluteString.hasPrefix(url.absoluteString) != true && !controller.loading { load(w) }
    }
    static func dismantleUIView(_ w: WKWebView, coordinator: ()) { w.configuration.userContentController.removeScriptMessageHandler(forName: "console") }
}
