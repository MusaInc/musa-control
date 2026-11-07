import SwiftUI
import PencilKit
import Photos
import AVFoundation

struct VisualsView: View {
    @Environment(AppModel.self) private var app
    @State private var tab = UserDefaults.standard.string(forKey: "visuals.tab") ?? "follow"
    @State private var project: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $tab) {
                    Label("Follow Agent", systemImage: "scope").tag("follow")
                    Label("Remote Desktop", systemImage: "display").tag("vnc")
                    Label("Screenshots", systemImage: "photo.on.rectangle").tag("shots")
                    Label("Previews", systemImage: "safari").tag("preview")
                }
                .pickerStyle(.segmented).frame(maxWidth: 560)
                Spacer()
                if tab == "shots" || tab == "preview" { ProjectPicker(selection: $project) }
            }
            .padding(10).background(Theme.raised)
            Group {
                switch tab {
                case "vnc": RemoteDesktopPanel(initialDisplay: "99")
                case "shots": ScreenshotGallery(project: project)
                case "preview":
                    if let project { PreviewPanel(projectId: project) } else { EmptyNote(icon: "safari", text: "Choose a project to preview") }
                default: FollowPanel()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.bg)
        .onChange(of: tab) { _, t in UserDefaults.standard.set(t, forKey: "visuals.tab") }
        .onAppear { if project == nil { project = app.workspaceProject } }
    }
}

// MARK: - Remote desktop

struct RemoteDesktopPanel: View {
    let initialDisplay: String
    var compact = false
    @Environment(AppModel.self) private var app
    @State private var displays: [Display] = []
    @State private var display = "99"
    @State private var control = false
    @State private var controller: VNCController?
    @State private var fullscreen = false
    @State private var typing = ""
    @State private var confirmControl = false

    var body: some View {
        VStack(spacing: 0) {
            if !compact { toolbar }
            ZStack(alignment: .bottomLeading) {
                if let controller {
                    VNCWebView(controller: controller).id("\(display)-\(controller.mode)")
                        .background(Color.black)
                    stats(controller)
                }
            }
            if control && !compact, let controller {
                HStack(spacing: 6) {
                    TextField("Type into the remote desktop…", text: $typing).font(Theme.mono)
                        .onSubmit { controller.type(typing + "\n"); typing = "" }
                        .padding(.horizontal, 8).frame(height: 30).background(Theme.bg, in: RoundedRectangle(cornerRadius: 6))
                    Button("Send") { controller.type(typing); typing = "" }.font(Theme.label)
                    Button("Paste") { controller.paste() }.font(Theme.label)
                    Button("Esc") { controller.key(0xff1b) }.font(Theme.label)
                    Button("Tab") { controller.key(0xff09) }.font(Theme.label)
                    Button("↩") { controller.key(0xff0d) }.font(Theme.label)
                }
                .padding(8).background(Theme.raised)
            }
        }
        .background(Color.black)
        .task { display = initialDisplay; await loadDisplays(); makeController() }
        .fullScreenCover(isPresented: $fullscreen) {
            ZStack(alignment: .topTrailing) {
                if let controller { VNCWebView(controller: VNCController(display: controller.display, mode: controller.mode)).ignoresSafeArea() }
                Button { fullscreen = false } label: { Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).padding(10).background(.ultraThinMaterial, in: Circle()) }
                    .buttonStyle(.plain).padding(16)
            }
            .background(Color.black)
        }
        .confirmationDialog("Take control of display :\(display)?", isPresented: $confirmControl, titleVisibility: .visible) {
            Button("Take control") { control = true; controller?.setMode("control"); makeController() }
        } message: {
            Text(displays.first { $0.display == display }?.native == true
                 ? "This desktop is shared with the Live Work agents. Your clicks and keys go to the same browser they use."
                 : "Your input goes straight to the program drawing on this display, which may be an automated test or capture.")
        }
    }

    var toolbar: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(displays) { d in Button { display = d.display; control = false; makeController() } label: { Label("\(d.label) · \(d.width ?? 0)×\(d.height ?? 0)", systemImage: d.display == display ? "checkmark" : "display") } }
                Button { Task { await loadDisplays() } } label: { Label("Refresh list", systemImage: "arrow.clockwise") }
            } label: {
                Label(displays.first { $0.display == display }?.label ?? "Display :\(display)", systemImage: "display").font(Theme.label)
            }
            Divider().frame(height: 18)
            Picker("", selection: Binding(get: { control ? "control" : "observe" }, set: { v in if v == "control" { confirmControl = true } else { control = false; controller?.setMode("observe"); makeController() } })) {
                Label("Observe", systemImage: "eye").tag("observe")
                Label("Control", systemImage: "cursorarrow.click.2").tag("control")
            }
            .pickerStyle(.segmented).frame(width: 220)
            Text(displays.first { $0.display == display }?.controlledBy ?? "").font(Theme.caption).foregroundStyle(Theme.textFaint).lineLimit(1)
            Spacer()
            IconButton(systemName: "arrow.clockwise", help: "Reconnect") { controller?.reconnect() }
            IconButton(systemName: "arrow.up.left.and.arrow.down.right", help: "Full screen") { fullscreen = true }
        }
        .padding(.horizontal, 10).frame(height: 40).background(Theme.raised)
    }

    func stats(_ c: VNCController) -> some View {
        HStack(spacing: 8) {
            StatusDot(status: c.connected ? "idle" : "approval", size: 6)
            Text(c.connected ? (control ? "Controlling" : "Observing (view-only)") : c.status)
            if let rtt = c.rtt { Text("· \(rtt) ms") }
            if let k = c.kbps, c.connected { Text("· \(k > 1000 ? String(format: "%.1f Mb/s", Double(k) / 1000) : "\(k) kb/s")") }
            if let s = c.size { Text("· \(Int(s.width))×\(Int(s.height))") }
        }
        .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 8).padding(.vertical, 4).background(.black.opacity(0.55), in: Capsule()).padding(8)
        .allowsHitTesting(false)
    }

    func makeController() { controller = VNCController(display: display, mode: control ? "control" : "observe") }
    func loadDisplays() async { if let d = try? await app.client.get("/api/vnc/displays", as: [Display].self) { displays = d } }
}

// MARK: - Screenshots

struct ScreenshotGallery: View {
    let project: String?
    @Environment(AppModel.self) private var app
    @State private var shots: [Screenshot] = []
    @State private var open: Screenshot?
    @State private var compareA: Screenshot?
    @State private var compare: (Screenshot, Screenshot)?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 12) {
                ForEach(shots) { s in
                    Button { open = s } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            AuthImage(path: "/api/screenshots/\(s.id)/image", query: ["w": "480"], contentMode: .fill)
                                .frame(height: 130).frame(maxWidth: .infinity).clipped().clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(compareA?.id == s.id ? Theme.accent : Theme.line, lineWidth: compareA?.id == s.id ? 2 : 1))
                            Text(s.name).font(Theme.caption).lineLimit(1)
                            HStack(spacing: 4) {
                                Text(app.project(s.project)?.name ?? "—")
                                Text("·"); Text(Fmt.ago(s.ts))
                                if s.source == "agent" { Image(systemName: "sparkles") }
                                if let w = s.width, let h = s.height { Spacer(); Text("\(w)×\(h)") }
                            }
                            .font(.system(size: 10)).foregroundStyle(Theme.textFaint)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button { if let a = compareA, a.id != s.id { compare = (a, s); compareA = nil } else { compareA = s } } label: {
                            Label(compareA == nil ? "Compare: pick as before" : "Compare with selected", systemImage: "square.split.2x1")
                        }
                        Button { open = s } label: { Label("Open", systemImage: "arrow.up.left.and.arrow.down.right") }
                    }
                }
            }
            .padding(12)
        }
        .overlay { if shots.isEmpty { EmptyNote(icon: "photo.on.rectangle", text: "No screenshots yet", detail: "Images that agents capture or view, and new images in watched projects, appear here automatically.") } }
        .task(id: project) { await load() }
        .onChange(of: app.eventTick) { _, _ in
            if let e = app.liveEvents.last, e.kind == "screenshot.new", project == nil || e.project == project { Task { await load() } }
        }
        .refreshable { await load() }
        .sheet(item: $open) { s in ScreenshotViewer(initial: s, all: shots) }
        .sheet(isPresented: Binding(get: { compare != nil }, set: { if !$0 { compare = nil } })) { if let c = compare { CompareView(a: c.0, b: c.1) } }
    }

    func load() async {
        if let s = try? await app.client.get("/api/screenshots", ["project": project, "limit": "300"], as: [Screenshot].self) { shots = s }
    }
}

struct ScreenshotDetail: View {
    let shot: Screenshot
    @Environment(AppModel.self) private var app
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            Color.black
            if let image { ZoomableImage(image: image) } else { ProgressView() }
        }
        .task(id: shot.id) { image = await ImageCache.shared.image(client: app.client, path: "/api/screenshots/\(shot.id)/image", query: [:]) }
    }
}

struct ScreenshotViewer: View {
    let initial: Screenshot
    let all: [Screenshot]
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var current: Screenshot?
    @State private var annotate = false
    @State private var canvas = PKCanvasView()
    @State private var note = ""
    @State private var sendTo: String?
    @State private var status: String?
    @State private var image: UIImage?

    var shot: Screenshot { current ?? initial }
    var index: Int { all.firstIndex(of: shot) ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(shot.name).font(Theme.title).lineLimit(1)
                    Text("\(app.project(shot.project)?.name ?? "—") · \(Fmt.time(shot.ts)) · \(shot.width ?? 0)×\(shot.height ?? 0) · \(shot.source)").font(Theme.caption).foregroundStyle(Theme.textDim)
                }
                Spacer()
                IconButton(systemName: "chevron.left", help: "Newer") { if index > 0 { current = all[index - 1] } }.keyboardShortcut(.leftArrow, modifiers: [])
                IconButton(systemName: "chevron.right", help: "Older") { if index + 1 < all.count { current = all[index + 1] } }.keyboardShortcut(.rightArrow, modifiers: [])
                IconButton(systemName: annotate ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle", help: "Annotate", tint: annotate ? Theme.accent : Theme.textDim) { annotate.toggle() }
                IconButton(systemName: "square.and.arrow.down", help: "Save to Photos") { save() }
                IconButton(systemName: "xmark", help: "Close") { dismiss() }
            }
            .padding(10).background(Theme.raised)
            ZStack {
                Color.black
                if let image {
                    if annotate {
                        Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                            .overlay(CanvasRepresentable(canvas: canvas))
                    } else { ZoomableImage(image: image) }
                } else { ProgressView() }
            }
            HStack(spacing: 8) {
                TextField("Feedback for the agent (optional)…", text: $note, axis: .vertical).lineLimit(1...4)
                    .padding(8).background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
                Menu {
                    ForEach(app.agents.filter { $0.controllable && $0.isLive }) { a in Button("\(a.agentName): \(a.title)") { sendTo = a.id; send() } }
                } label: {
                    Label("Send to agent", systemImage: "paperplane").font(Theme.label).padding(.horizontal, 12).frame(height: 34)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8)).foregroundStyle(.black)
                }
                .disabled(app.agents.filter { $0.controllable && $0.isLive }.isEmpty)
            }
            .padding(10).background(Theme.raised)
            if let status { Text(status).font(Theme.caption).foregroundStyle(Theme.textDim).padding(.bottom, 6) }
        }
        .background(Theme.bg)
        .task(id: shot.id) { image = nil; canvas.drawing = PKDrawing(); image = await ImageCache.shared.image(client: app.client, path: "/api/screenshots/\(shot.id)/image", query: [:]) }
    }

    func annotatedPNG() -> String? {
        guard annotate, !canvas.drawing.bounds.isEmpty, let image else { return nil }
        let size = canvas.bounds.size
        let r = UIGraphicsImageRenderer(size: size)
        let out = r.image { _ in
            image.draw(in: AVMakeRect(aspectRatio: image.size, insideRect: CGRect(origin: .zero, size: size)))
            canvas.drawing.image(from: CGRect(origin: .zero, size: size), scale: 1).draw(at: .zero)
        }
        return out.pngData()?.base64EncodedString()
    }

    func send() {
        guard let to = sendTo else { return }
        var body: [String: Any] = ["agent": to, "text": note.isEmpty ? "Here is a screenshot to look at." : note]
        if let png = annotatedPNG() { body["annotatedPng"] = png }
        status = "Sending…"
        Task {
            do { _ = try await app.client.send("POST", "/api/screenshots/\(shot.id)/send", body, as: OK.self); status = "Sent to \(app.agent(to)?.agentName ?? "agent")."; note = "" }
            catch { status = error.localizedDescription }
        }
    }

    func save() {
        guard let image else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { s in
            guard s == .authorized || s == .limited else { return }
            PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAsset(from: image) }
        }
        status = "Saved to Photos"
    }
}

struct CanvasRepresentable: UIViewRepresentable {
    let canvas: PKCanvasView
    func makeUIView(context: Context) -> PKCanvasView {
        canvas.backgroundColor = .clear; canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: UIColor(red: 0.98, green: 0.36, blue: 0.36, alpha: 1), width: 6)
        return canvas
    }
    func updateUIView(_ v: PKCanvasView, context: Context) {}
}

/// Before/after: side by side, or overlaid with a drag slider.
struct CompareView: View {
    let a: Screenshot
    let b: Screenshot
    @Environment(\.dismiss) private var dismiss
    @State private var mode = "slider"
    @State private var split: CGFloat = 0.5
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Compare").font(Theme.title)
                Text("\(a.name) → \(b.name)").font(Theme.caption).foregroundStyle(Theme.textDim).lineLimit(1)
                Spacer()
                Picker("", selection: $mode) { Text("Slider").tag("slider"); Text("Side by side").tag("side") }.pickerStyle(.segmented).frame(width: 220)
                IconButton(systemName: "xmark", help: "Close") { dismiss() }
            }
            .padding(10).background(Theme.raised)
            GeometryReader { g in
                if mode == "side" {
                    HStack(spacing: 2) {
                        AuthImage(path: "/api/screenshots/\(a.id)/image").frame(maxWidth: .infinity)
                        AuthImage(path: "/api/screenshots/\(b.id)/image").frame(maxWidth: .infinity)
                    }
                } else {
                    ZStack(alignment: .leading) {
                        AuthImage(path: "/api/screenshots/\(b.id)/image")
                        AuthImage(path: "/api/screenshots/\(a.id)/image")
                            .mask(alignment: .leading) { Rectangle().frame(width: g.size.width * split) }
                        Rectangle().fill(Theme.accent).frame(width: 2).offset(x: g.size.width * split - 1)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in split = min(1, max(0, v.location.x / g.size.width)) })
                }
            }
            .background(Color.black)
        }
    }
}

// MARK: - Live preview

struct PreviewPanel: View {
    let projectId: String
    @Environment(AppModel.self) private var app
    @State private var sources: PreviewsResponse?
    @State private var selected: String?
    @State private var controller = PreviewController()
    @State private var width: CGFloat? = nil
    @State private var showConsole = false
    @State private var status: String?

    struct Source: Identifiable, Hashable { let id: String; let label: String; let url: URL; let kind: String }
    var all: [Source] {
        guard let s = sources else { return [] }
        var out: [Source] = []
        for l in s.local { if let u = URL(string: "mcpreview://\(l.port)/") { out.append(Source(id: "local-\(l.port)", label: "\(l.process ?? "server") :\(l.port)", url: u, kind: "Dev server") ) } }
        for p in s.public { if let u = URL(string: p.url) { out.append(Source(id: p.url, label: p.label, url: u, kind: "Public")) } }
        for st in s.static { if let u = URL(string: st.url) { out.append(Source(id: st.url, label: st.label, url: u, kind: "Static build")) } }
        return out
    }
    var current: Source? { all.first { $0.id == selected } ?? all.first }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(all) { s in Button { selected = s.id } label: { Label("\(s.label) — \(s.kind)", systemImage: s.id == current?.id ? "checkmark" : "globe") } }
                    Button { Task { await load() } } label: { Label("Refresh sources", systemImage: "arrow.clockwise") }
                } label: { Label(current?.label ?? "No preview", systemImage: "safari").font(Theme.label).lineLimit(1) }
                if let k = current?.kind { Pill(text: k) }
                Spacer()
                Picker("", selection: Binding(get: { width ?? 0 }, set: { width = $0 == 0 ? nil : $0 })) {
                    Text("Fill").tag(CGFloat(0)); Text("Phone").tag(CGFloat(390)); Text("Tablet").tag(CGFloat(820)); Text("Desktop").tag(CGFloat(1280))
                }.pickerStyle(.segmented).frame(width: 260)
                IconButton(systemName: "camera", help: "Capture preview screenshot") { capture() }
                IconButton(systemName: showConsole ? "terminal.fill" : "terminal", help: "Console") { showConsole.toggle() }
                IconButton(systemName: "arrow.clockwise", help: "Reload (⌘R)") { controller.reload() }.keyboardShortcut("r", modifiers: .command)
            }
            .padding(.horizontal, 10).frame(height: 38).background(Theme.raised)
            if let src = current {
                GeometryReader { g in
                    ZStack {
                        Theme.bg
                        PreviewWebView(url: src.url, controller: controller, needsCookie: src.kind == "Static build").id(src.id)
                            .frame(width: width.map { min($0, g.size.width) } ?? g.size.width)
                            .overlay { if let w = width { RoundedRectangle(cornerRadius: 0).stroke(Theme.lineStrong).frame(width: min(w, g.size.width)) } }
                    }
                }
                if let e = controller.error { Text(e).font(Theme.caption).foregroundStyle(Theme.red).padding(6) }
                if showConsole {
                    ScrollView { VStack(alignment: .leading, spacing: 2) { ForEach(Array(controller.console.enumerated()), id: \.offset) { _, l in Text(l).font(Theme.monoSmall).foregroundStyle(l.hasPrefix("error") ? Theme.red : l.hasPrefix("warn") ? Theme.yellow : Theme.textDim) } }.frame(maxWidth: .infinity, alignment: .leading).padding(8) }
                        .frame(height: 160).background(Theme.bg)
                }
            } else {
                EmptyNote(icon: "safari", text: "Nothing to preview", detail: "Start a dev server inside the project (it appears here automatically), or build a web export. Native iOS apps need a Mac simulator and are not shown as web previews.")
            }
            if let status { Text(status).font(Theme.caption).foregroundStyle(Theme.textDim).padding(4) }
        }
        .task(id: projectId) { await load() }
    }

    func load() async { sources = try? await app.client.get("/api/projects/\(projectId)/previews", as: PreviewsResponse.self) }

    func capture() {
        Task {
            guard let img = await controller.snapshot(), let png = img.pngData() else { status = "Couldn't capture"; return }
            let name = "preview-\(Int(Date().timeIntervalSince1970)).png"
            do {
                _ = try await app.client.upload("/api/screenshots", query: ["project": projectId, "name": name], data: png, as: Screenshot.self)
                status = "Captured \(name) — it's in Screenshots."
            } catch { status = error.localizedDescription }
        }
    }
}
