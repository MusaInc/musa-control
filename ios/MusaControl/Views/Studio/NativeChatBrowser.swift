import SwiftUI
import WebKit

@MainActor
@Observable
final class NativeChatBrowser: NSObject, WKNavigationDelegate, WKUIDelegate {
    static let home = URL(string: "https://chatgpt.com/")!

    @ObservationIgnored private(set) var main: WKWebView?
    private(set) var popup: WKWebView?
    private(set) var issue: String?
    private(set) var loading = false
    @ObservationIgnored private var boundConversation: URL?

    var visibleWebView: WKWebView? { popup ?? main }

    static func conversation(_ input: String?) -> URL? {
        guard let input, var parts = URLComponents(string: input),
              parts.scheme == "https", parts.host == "chatgpt.com", parts.port == nil,
              parts.user == nil, parts.password == nil,
              parts.path.range(of: #"^/(?:g/g-p-[A-Za-z0-9-]+/)?c/[a-fA-F0-9-]{36}/?$"#,
                               options: .regularExpression) != nil else { return nil }
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }

    func prepare() {
        if main != nil { return }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .init(forIdentifier: UUID(uuidString: "02FC8CD1-F36D-42F3-934B-E1AC3D3D5543")!)
        config.allowsInlineMediaPlayback = true
        let view = WKWebView(frame: .zero, configuration: config)
        configure(view)
        main = view
        view.load(URLRequest(url: Self.home))
    }

    func follow(_ link: URL?) {
        prepare()
        guard let link, link != boundConversation else { return }
        boundConversation = link
        if popup != nil { return }
        main?.load(URLRequest(url: link))
    }

    func reloadConversation(_ link: URL?) {
        prepare()
        guard popup == nil, let main else { return }
        if let link {
            boundConversation = link
            main.load(URLRequest(url: link, cachePolicy: .reloadIgnoringLocalCacheData))
        } else if main.url != nil {
            main.reload()
        } else {
            main.load(URLRequest(url: Self.home))
        }
    }

    func clearBinding() {
        boundConversation = nil
        popup = nil
        main?.stopLoading()
        main?.removeFromSuperview()
        main = nil
        issue = nil
    }

    func suspendInput() {
        main?.endEditing(true)
        popup?.endEditing(true)
    }

    private func configure(_ view: WKWebView) {
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.scrollView.keyboardDismissMode = .interactive
    }

    private func permitted(_ url: URL) -> Bool {
        if url.absoluteString == "about:blank" { return true }
        guard url.scheme == "https", let host = url.host?.lowercased(),
              url.port == nil, url.user == nil, url.password == nil else { return false }
        return ["chatgpt.com", "auth.openai.com", "accounts.openai.com",
                "appleid.apple.com", "login.microsoftonline.com", "login.live.com"].contains(host)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if navigationAction.targetFrame?.isMainFrame == false {
            decisionHandler(.allow)
        } else if permitted(url) {
            decisionHandler(.allow)
        } else {
            if url.host == "accounts.google.com" {
                issue = "Google sign-in requires a supported browser. Use the signed-in VPS browser or open ChatGPT in Safari."
            } else if navigationAction.navigationType == .linkActivated {
                issue = "This link opens outside the embedded ChatGPT browser. Use Open in Safari to continue."
            } else {
                issue = "This sign-in redirected outside the embedded browser. Use the VPS browser or Safari."
            }
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard popup == nil, let url = navigationAction.request.url, permitted(url) else { return nil }
        let view = WKWebView(frame: .zero, configuration: configuration)
        configure(view)
        popup = view
        return view
    }

    func webViewDidClose(_ webView: WKWebView) {
        if popup === webView { popup = nil }
    }

    func closePopup() { popup = nil }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        issue = nil
        loading = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading = false }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { show(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { show(error) }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loading = false
        issue = "WebKit disconnected. Reload the ChatGPT conversation to continue."
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(origin.host == "chatgpt.com" && frame.isMainFrame && type == .microphone ? .prompt : .deny)
    }

    private func show(_ error: Error) {
        loading = false
        let error = error as NSError
        guard error.code != NSURLErrorCancelled else { return }
        issue = "ChatGPT couldn’t load in the embedded browser. Reload the page or use the VPS browser."
    }
}

struct NativeChatBrowserHost: UIViewRepresentable {
    let webView: WKWebView?

    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        attach(to: host)
        return host
    }

    func updateUIView(_ view: UIView, context: Context) { attach(to: view) }

    private func attach(to host: UIView) {
        host.subviews.filter { $0 !== webView }.forEach { $0.removeFromSuperview() }
        guard let webView, webView.superview !== host else { return }
        webView.frame = host.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(webView)
    }
}
