import SwiftUI
import WebKit
import QuickLook

struct VisualItem: Codable, Identifiable, Hashable {
    var id: String { path }
    let path: String
    let name: String
    let kind: String
    let size: Double?
    let mtime: Double
    let run: String?
    let linked: Bool?

    init(path: String, name: String, kind: String, size: Double?, mtime: Double, run: String? = nil, linked: Bool? = nil) {
        self.path = path; self.name = name; self.kind = kind; self.size = size; self.mtime = mtime; self.run = run; self.linked = linked
    }
    init(event: TimelineEvent) {
        let p = event.detail?["path"]?.string ?? ""
        self.init(path: p, name: (p as NSString).lastPathComponent, kind: event.detail?["kind"]?.string ?? "other",
                  size: event.detail?["size"]?.number, mtime: event.detail?["mtime"]?.number ?? event.ts)
    }
    var icon: String {
        switch kind {
        case "image": return "photo"; case "svg": return "scribble.variable"; case "video": return "play.rectangle"
        case "html": return "globe"; case "model": return "cube"; case "pdf": return "doc.richtext"; case "text": return "doc.plaintext"
        default: return "doc"
        }
    }
}
struct VisualList: Codable { let project: String; let dir: String; let items: [VisualItem] }
struct VisualRun: Codable, Identifiable { let id: String; let status: String; let exitCode: Int?; let output: String; let files: [String]?; let sandbox: String?; let startedAt: Double; let endedAt: Double? }
struct VisualStatus: Codable { let sandbox: String?; let python: String; let venv: Bool; let packages: [String: Bool]; let dir: String }

/// Live outputs from agents and Python runs. The newest output is shown as
/// it lands (while Live is on); every change re-renders it. Pages render
/// through the app's own mcvisual:// scheme, an origin with no access to
/// the gateway, so a generated page can't use your session.
struct VisualiserPanel: View {
    let projectId: String?
    let selected: String?
    let select: (String?) -> Void
    @Environment(AppModel.self) private var app
    @State private var items: [VisualItem] = []
    @State private var shared: [VisualItem] = []
    @State private var live = true
    @State private var showList = true
    @State private var runner = false
    @State private var dir: String?
    @AppStorage("visual.source") private var source = "outputs"   // outputs | captures

    var project: String { projectId ?? "_shared" }
    var all: [VisualItem] { (items + shared.map { VisualItem(path: "@shared/" + $0.path, name: $0.name, kind: $0.kind, size: $0.size, mtime: $0.mtime, run: $0.run, linked: $0.linked) }).sorted { $0.mtime > $1.mtime } }
    var shownItem: VisualItem? { live ? all.first : (all.first { $0.path == selected } ?? all.first) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if source == "captures" {
                ScreenshotGallery(project: projectId).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            HStack(spacing: 0) {
                if showList && !all.isEmpty { list.frame(width: 190); Rectangle().fill(Theme.line).frame(width: 1) }
                Group {
                    if let it = shownItem {
                        let (proj, path) = split(it.path)
                        VisualItemView(project: proj, item: VisualItem(path: path, name: it.name, kind: it.kind, size: it.size, mtime: it.mtime)).id("\(it.path)@\(it.mtime)")
                    } else { empty }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            }
        }
        .background(Theme.surface)
        .task(id: project) { await load() }
        .onChange(of: app.eventTick) { _, _ in
            guard let e = app.liveEvents.last, e.kind.hasPrefix("visual."), e.project == project || e.project == "_shared" else { return }
            Task { await load() }
        }
        .sheet(isPresented: $runner) { PythonRunnerSheet(projectId: projectId) }
    }

    func split(_ p: String) -> (String, String) { p.hasPrefix("@shared/") ? ("_shared", String(p.dropFirst(8))) : (project, p) }

    var toolbar: some View {
        HStack(spacing: 4) {
            Picker("Source", selection: $source) { Text("Outputs").tag("outputs"); Text("Captures").tag("captures") }
                .pickerStyle(.segmented).frame(width: 170)
                .help("Outputs: what agents and Python runs publish. Captures: screenshots agents took or looked at.")
            if source == "outputs" { outputsControls }
            Spacer()
            if source == "outputs" { outputsActions }
        }
        .padding(.horizontal, 6).frame(height: 32)
        .background(Theme.bg)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    @ViewBuilder var outputsControls: some View {
            Button { live.toggle(); if live { select(nil) } } label: {
                Label(live ? "Live" : "Pinned", systemImage: live ? "dot.radiowaves.left.and.right" : "pin.fill")
                    .font(.system(size: 11.5, weight: .semibold)).padding(.horizontal, 8).frame(height: 22)
                    .background(live ? Theme.green.opacity(0.16) : Theme.hover, in: Capsule())
                    .foregroundStyle(live ? Theme.green : Theme.textDim)
            }
            .buttonStyle(.plain)
            .help(live ? "Showing the newest output as it changes" : "Showing the output you picked")
            .accessibilityIdentifier("visual.live")
            if let it = shownItem {
                Text(it.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(Fmt.ago(it.mtime)).font(.system(size: 11)).foregroundStyle(Theme.textFaint)
            }
    }

    @ViewBuilder var outputsActions: some View {
            IconButton(systemName: "play.rectangle", help: "Run Python in the sandbox") { runner = true }
                .accessibilityIdentifier("visual.run")
            IconButton(systemName: showList ? "sidebar.left" : "sidebar.squares.left", help: showList ? "Hide outputs list" : "Show outputs list") { showList.toggle() }
            Menu {
                if let it = shownItem {
                    Button(role: .destructive) { Task { let (p, path) = split(it.path); _ = try? await app.client.send("DELETE", "/api/visuals/\(p.pathSegment)/file", query: ["path": path], as: OK.self); await load() } } label: { Label("Remove \(it.name)", systemImage: "trash") }
                }
                if let dir { Button { UIPasteboard.general.string = dir } label: { Label("Copy folder path (agents: $MUSA_PREVIEW_DIR)", systemImage: "doc.on.doc") } }
                Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            } label: { Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textDim).frame(width: 30, height: 30) }
    }

    var list: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(all) { it in
                    let on = shownItem?.path == it.path
                    Button { live = false; select(it.path) } label: {
                        HStack(spacing: 7) {
                            Image(systemName: it.icon).font(.system(size: 12)).foregroundStyle(on ? Theme.accent : Theme.textDim).frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(it.name).font(.system(size: 12.5, weight: on ? .semibold : .regular)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                                Text([it.run != nil ? "run" : nil, it.path.hasPrefix("@shared/") ? "shared" : nil, Fmt.ago(it.mtime)].compactMap { $0 }.joined(separator: " · "))
                                    .font(.system(size: 10.5)).foregroundStyle(Theme.textFaint)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8).frame(height: 38)
                        .background(on ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
        }
        .background(Theme.bg)
    }

    var empty: some View {
        VStack(spacing: 10) {
            EmptyNote(icon: "chart.xyaxis.line", text: "Nothing to show yet",
                      detail: "Charts, images, 3D models, HTML apps and videos appear here as soon as an agent saves them into its preview folder ($MUSA_PREVIEW_DIR, or `musa-preview file`) or a Python run creates them.")
            Button { runner = true } label: { Label("Run Python…", systemImage: "play.rectangle") }.buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func load() async {
        if let l = try? await app.client.get("/api/visuals/\(project.pathSegment)", as: VisualList.self) { items = l.items; dir = l.dir }
        if project != "_shared", let s = try? await app.client.get("/api/visuals/_shared", as: VisualList.self) { shared = s.items } else { shared = [] }
    }
}

/// Renders one output by kind. Everything web-renderable goes through the
/// mcvisual:// scheme; text is read and highlighted; USDZ opens Quick Look.
struct VisualItemView: View {
    let project: String
    let item: VisualItem
    @Environment(AppModel.self) private var app
    @State private var text: String?
    @State private var quickLook: URL?

    var body: some View {
        Group {
            switch item.kind {
            case "text":
                if let text { CodeView(text: text, path: item.name) } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            case "model" where item.name.lowercased().hasSuffix(".usdz"):
                VStack(spacing: 10) {
                    EmptyNote(icon: "cube", text: item.name, detail: "USDZ opens in Quick Look (rotate, zoom, AR).")
                    Button("Open in Quick Look") { Task { quickLook = await download() } }.buttonStyle(.borderedProminent).tint(Theme.accent)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            case "other":
                EmptyNote(icon: "doc", text: item.name, detail: "This file type has no preview. \(Fmt.bytes(item.size))")
            default:
                VisualWebView(url: VisualScheme.url(for: item, project: project))
            }
        }
        .task(id: "\(item.path)@\(item.mtime)") {
            guard item.kind == "text" else { return }
            if let d = try? await app.client.raw(app.client.request("GET", "/api/visuals/\(project.pathSegment)/file", query: ["path": item.path])) {
                text = String(decoding: d.prefix(2_000_000), as: UTF8.self)
            }
        }
        .quickLookPreview($quickLook)
    }

    func download() async -> URL? {
        guard let d = try? await app.client.raw(app.client.request("GET", "/api/visuals/\(project.pathSegment)/file", query: ["path": item.path], timeout: 120)) else { return nil }
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(item.name)
        try? d.write(to: u)
        return u
    }
}

enum VisualScheme {
    static let scheme = "mcvisual"
    static func url(for item: VisualItem, project: String) -> URL {
        let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s }
        let file = "\(scheme)://x/files/\(enc(project))/\(enc(item.path))?v=\(Int(item.mtime))"
        if item.kind == "model" {
            let src = file.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? file
            let ext = (item.name as NSString).pathExtension.lowercased()
            return URL(string: "\(scheme)://x/viewer/model.html?ext=\(ext)&src=\(src)")!
        }
        if item.kind == "image" || item.kind == "svg" {
            // A tiny page so the picture fits the panel and pinch-zooms.
            let src = file.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? file
            return URL(string: "\(scheme)://x/image?src=\(src)")!
        }
        return URL(string: file)!
    }
}

/// mcvisual://x/files/<project>/<path> → the project's preview folder,
/// mcvisual://x/viewer/<file> → the gateway's 3D viewer, read with the
/// device token. Nothing else is reachable from these pages.
final class VisualSchemeHandler: NSObject, WKURLSchemeHandler {
    let client: GatewayClient
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    init(client: GatewayClient) { self.client = client }

    static let imagePage = """
    <!doctype html><meta name="viewport" content="width=device-width, initial-scale=1"><style>
    :root{--bg:#f4f4f5}@media (prefers-color-scheme: dark){:root{--bg:#111214}}
    html,body{margin:0;height:100%;background:var(--bg)}body{display:flex;align-items:center;justify-content:center}
    img{max-width:100%;max-height:100%;object-fit:contain;image-rendering:auto}</style><img id=i>
    <script>document.getElementById('i').src=new URLSearchParams(location.search).get('src')</script>
    """

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { task.didFailWithError(URLError(.badURL)); return }
        let parts = comps.path.split(separator: "/", omittingEmptySubsequences: true).map { String($0).removingPercentEncoding ?? String($0) }
        if parts.first == "image" {
            let data = Data(Self.imagePage.utf8)
            task.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
            task.didReceive(data); task.didFinish(); return
        }
        var req: URLRequest
        if parts.first == "files", parts.count >= 3 {
            req = client.request("GET", "/api/visuals/\(parts[1].pathSegment)/file", query: ["path": parts.dropFirst(2).joined(separator: "/")], timeout: 120)
        } else if parts.first == "viewer", parts.count >= 2 {
            req = client.request("GET", "/api/viewer/" + parts.dropFirst().map { $0.pathSegment }.joined(separator: "/"), timeout: 60)
        } else { task.didFailWithError(URLError(.fileDoesNotExist)); return }
        if let range = task.request.value(forHTTPHeaderField: "Range") { req.setValue(range, forHTTPHeaderField: "Range") }
        let key = ObjectIdentifier(task)
        tasks[key] = Task {
            do {
                let (data, http) = try await client.transport.send(req)
                var headers: [String: String] = [:]
                for (k, v) in http.allHeaderFields { if let k = k as? String, let v = v as? String, !["content-security-policy", "content-encoding", "content-length", "set-cookie"].contains(k.lowercased()) { headers[k] = v } }
                headers["Content-Length"] = String(data.count)
                headers["Cache-Control"] = "no-store"
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

struct VisualWebView: UIViewRepresentable {
    let url: URL
    @Environment(AppModel.self) private var app
    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(VisualSchemeHandler(client: app.client), forURLScheme: VisualScheme.scheme)
        cfg.websiteDataStore = .nonPersistent()     // no cookies, no storage shared with anything
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.isOpaque = false
        w.backgroundColor = UIColor(Theme.surface)
        w.isInspectable = true
        w.load(URLRequest(url: url))
        return w
    }
    func updateUIView(_ w: WKWebView, context: Context) {
        if w.url != url && !w.isLoading { w.load(URLRequest(url: url)) }
    }
}

/// Write or pick a script and run it in the machine's sandbox (no network,
/// read-only project, writes only to its own output folder).
struct PythonRunnerSheet: View {
    let projectId: String?
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @AppStorage("visual.lastScript") private var code = """
    import numpy as np
    import matplotlib.pyplot as plt

    x = np.linspace(0, 4 * np.pi, 400)
    plt.plot(x, np.sin(x), label="sin")
    plt.plot(x, np.cos(x), label="cos")
    plt.legend(); plt.title("Hello from the sandbox")
    plt.show()
    """
    @State private var file = ""
    @State private var source = "code"
    @State private var run: VisualRun?
    @State private var status: VisualStatus?
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Source", selection: $source) { Text("Script").tag("code"); Text("Project file").tag("file") }
                    .pickerStyle(.segmented).padding(10)
                if source == "code" {
                    CodeEditor(text: $code, path: "script.py", onSave: { start() })
                        .frame(maxHeight: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Path inside the project, e.g. tools/plot.py", text: $file)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().font(Theme.mono)
                            .padding(8).background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
                        Text("The script can read the project (read-only). Files it writes land in the Visualiser.").font(Theme.caption).foregroundStyle(Theme.textDim)
                        Spacer()
                    }.padding(12)
                }
                Divider()
                outputBox
            }
            .navigationTitle("Run Python")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { start() } label: { Label(busy ? "Running…" : "Run", systemImage: "play.fill") }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(busy || (source == "file" && file.isEmpty) || status?.sandbox == nil)
                }
            }
        }
        .task {
            status = try? await app.client.get("/api/visuals/status", as: VisualStatus.self)
            if let p = projectId, let open = FilesState.shared.openPath[p], open.hasSuffix(".py") { file = open }
        }
    }

    @ViewBuilder var outputBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let s = status {
                    if s.sandbox == nil { Label("No sandbox on this machine (install bubblewrap); runs are disabled.", systemImage: "lock.slash").foregroundStyle(Theme.red) }
                    else { Label("Sandboxed (\(s.sandbox ?? "")) · no network", systemImage: "lock.shield").foregroundStyle(Theme.textDim) }
                    if s.packages["matplotlib"] != true {
                        Button("Install matplotlib, numpy, Pillow") { Task { _ = try? await app.client.send("POST", "/api/visuals/setup", ["confirm": true], as: JSONValue.self); error = "Installing in the background — try again in a minute." } }
                            .font(Theme.caption)
                    }
                }
                Spacer()
                if let r = run { Pill(text: r.status, color: r.status == "ok" ? Theme.green : r.status == "running" ? Theme.blue : Theme.red) }
            }
            .font(Theme.caption)
            if let error { Text(error).font(Theme.caption).foregroundStyle(Theme.red) }
            ScrollView {
                Text(run?.output.isEmpty == false ? run!.output : (run == nil ? "Output appears here. Figures from plt.show(), Image.show() and fig.show() are saved as files and shown in the Visualiser." : "(no output)"))
                    .font(Theme.monoSmall).foregroundStyle(Theme.textDim).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 150)
        }
        .padding(10).background(Theme.raised)
    }

    func start() {
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                let body: [String: Any] = source == "code" ? ["code": code] : ["file": file]
                var r = try await app.client.send("POST", "/api/visuals/\((projectId ?? "_shared").pathSegment)/run", body, as: VisualRun.self)
                run = r
                while r.status == "running" {
                    try await Task.sleep(nanoseconds: 600_000_000)
                    r = try await app.client.get("/api/visual-runs/\(r.id)", as: VisualRun.self)
                    run = r
                }
                if r.status == "ok" { app.workspace.reveal(.visualiser) }
            } catch { self.error = error.localizedDescription }
        }
    }
}
