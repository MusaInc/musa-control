import SwiftUI
import AVKit
import PDFKit
import UniformTypeIdentifiers

/// Which file is open per project, shared by the Files section, workspace
/// panels and "Open" buttons elsewhere.
@MainActor
@Observable
final class FilesState {
    static let shared = FilesState()
    var openPath: [String: String] = (UserDefaults.standard.dictionary(forKey: "files.open") as? [String: String]) ?? [:]
    var browsePath: [String: String] = [:]
    var jumpLine: Int?
    func open(project: String, path: String, line: Int? = nil) {
        openPath[project] = path
        browsePath[project] = (path as NSString).deletingLastPathComponent
        jumpLine = line
        UserDefaults.standard.set(openPath, forKey: "files.open")
    }
}

struct FilesSectionView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            HStack { ProjectPicker(selection: $app.filesProject); Spacer() }.padding(8).background(Theme.raised)
            if let p = app.filesProject {
                HStack(spacing: 0) {
                    FileBrowser(projectId: p).frame(width: 300)
                    Divider().overlay(Theme.line)
                    FileViewerPanel(projectId: p)
                }
            } else { EmptyNote(icon: "folder", text: "Choose a project") }
        }
        .background(Theme.bg)
        .onAppear { if app.filesProject == nil { app.filesProject = app.workspaceProject ?? app.projects.first?.id } }
        .onChange(of: app.projects.count) { _, _ in if app.filesProject == nil { app.filesProject = app.workspaceProject ?? app.projects.first?.id } }
    }
}

struct FileBrowser: View {
    let projectId: String
    @Environment(AppModel.self) private var app
    @State private var files = FilesState.shared
    @State private var listing: DirListing?
    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var searchMode = "name"
    @State private var gitFiles: [String: String] = [:]
    @State private var showHidden = false
    @State private var importing = false
    @State private var renaming: FileEntry?
    @State private var newName = ""
    @State private var deleting: FileEntry?
    @State private var error: String?
    @State private var recent: Set<String> = []

    var dir: String { files.browsePath[projectId] ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textFaint)
                TextField(searchMode == "name" ? "Find file" : "Search in files", text: $query).font(.system(size: 14)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit { Task { await search() } }
                Picker("", selection: $searchMode) { Image(systemName: "doc").tag("name"); Image(systemName: "text.magnifyingglass").tag("content") }.pickerStyle(.segmented).frame(width: 74)
            }
            .padding(.horizontal, 8).frame(height: 36).background(Theme.raised)
            if !query.isEmpty {
                List(results, id: \.self) { r in
                    Button { files.open(project: projectId, path: r.path, line: r.line) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.path).font(Theme.monoSmall).lineLimit(1).truncationMode(.head)
                            if let t = r.text { Text("\(r.line ?? 0): \(t.trimmingCharacters(in: .whitespaces))").font(Theme.monoSmall).foregroundStyle(Theme.textDim).lineLimit(1) }
                        }
                    }.buttonStyle(.plain).listRowBackground(Theme.surface)
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
                .overlay { if results.isEmpty { Text("Press return to search").font(Theme.caption).foregroundStyle(Theme.textFaint) } }
            } else {
                breadcrumb
                List {
                    ForEach((listing?.entries ?? []).filter { showHidden || !($0.hidden ?? false) }) { e in row(e) }
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
                .refreshable { await load() }
            }
            if let error { Text(error).font(Theme.caption).foregroundStyle(Theme.red).padding(6) }
        }
        .background(Theme.surface)
        .task(id: "\(projectId)/\(dir)") { await load() }
        .onChange(of: app.eventTick) { _, _ in
            guard let e = app.liveEvents.last, e.project == projectId, e.kind == "file.changed" || e.kind == "agent.edit" else { return }
            if let p = e.detail?["path"]?.string { recent.insert(app.locate(p)?.rel ?? p) }
            Task { await load() }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
            guard case .success(let urls) = r else { return }
            Task {
                for u in urls {
                    let ok = u.startAccessingSecurityScopedResource(); defer { if ok { u.stopAccessingSecurityScopedResource() } }
                    guard let d = try? Data(contentsOf: u) else { continue }
                    do { _ = try await app.client.upload("/api/projects/\(projectId)/upload", query: ["path": (dir.isEmpty ? "" : dir + "/") + u.lastPathComponent], data: d, as: [String: String].self) }
                    catch { self.error = error.localizedDescription }
                }
                await load()
            }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("New path", text: $newName)
            Button("Rename") { if let r = renaming { op { _ = try await app.client.send("POST", "/api/projects/\(projectId)/move", ["from": r.path, "to": newName], as: [String: String].self) } } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let d = deleting { op { _ = try await app.client.raw(app.client.request("DELETE", "/api/projects/\(projectId)/file", query: ["path": d.path])) } } }
        } message: { Text("It moves to the Musa Control trash on the server and can be restored from Settings → Trash.") }
    }

    var breadcrumb: some View {
        HStack(spacing: 4) {
            Button { files.browsePath[projectId] = "" } label: { Image(systemName: "house") }.buttonStyle(.plain)
            ForEach(Array(dir.split(separator: "/").enumerated()), id: \.offset) { i, part in
                Text("/").foregroundStyle(Theme.textFaint)
                Button(String(part)) { files.browsePath[projectId] = dir.split(separator: "/").prefix(i + 1).joined(separator: "/") }.buttonStyle(.plain).lineLimit(1)
            }
            Spacer()
            Menu {
                Button { importing = true } label: { Label("Upload files", systemImage: "square.and.arrow.up") }
                Button { op { _ = try await app.client.send("POST", "/api/projects/\(projectId)/mkdir", ["path": (dir.isEmpty ? "" : dir + "/") + "new-folder"], as: [String: String].self) } } label: { Label("New folder", systemImage: "folder.badge.plus") }
                Toggle("Show hidden files", isOn: $showHidden)
            } label: { Image(systemName: "ellipsis.circle").frame(width: 28, height: 28) }
        }
        .font(Theme.caption).foregroundStyle(Theme.textDim).padding(.horizontal, 10).frame(height: 30)
    }

    @ViewBuilder func row(_ e: FileEntry) -> some View {
        Button {
            if e.dir { files.browsePath[projectId] = e.path } else { files.open(project: projectId, path: e.path) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: e.dir ? "folder.fill" : icon(e.name)).font(.system(size: 13)).foregroundStyle(e.dir ? Theme.accent.opacity(0.8) : Theme.textDim).frame(width: 18)
                Text(e.name).font(.system(size: 14)).foregroundStyle(e.ignored == true ? Theme.textFaint : Theme.text).lineLimit(1)
                if recent.contains(e.path) { Circle().fill(Theme.blue).frame(width: 6, height: 6).help("Changed while you were watching") }
                Spacer()
                if let g = gitFiles[e.path] { Text(g).font(.system(size: 11.5, weight: .bold, design: .monospaced)).foregroundStyle(g == "?" || g == "A" ? Theme.green : g == "D" ? Theme.red : Theme.yellow) }
                if !e.dir { Text(Fmt.bytes(e.size)).font(.system(size: 11.5)).foregroundStyle(Theme.textFaint) }
            }
            .frame(height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(files.openPath[projectId] == e.path ? Theme.hover : Theme.surface)
        .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
        .contextMenu {
            Button { renaming = e; newName = e.path } label: { Label("Rename / move", systemImage: "pencil") }
            Button { op { _ = try await app.client.send("POST", "/api/projects/\(projectId)/move", ["from": e.path, "to": e.path + "-copy", "copy": true], as: [String: String].self) } } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            if !e.dir { Button { share(e) } label: { Label("Download / share", systemImage: "square.and.arrow.down") } }
            Button { UIPasteboard.general.string = e.path } label: { Label("Copy path", systemImage: "doc.on.doc") }
            Button(role: .destructive) { deleting = e } label: { Label("Delete…", systemImage: "trash") }
        }
    }

    func icon(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "svg": return "photo"
        case "mp4", "mov", "webm", "m4v": return "film"
        case "md": return "doc.richtext"
        case "json": return "curlybraces"
        case "pdf": return "doc.text.image"
        case "sh": return "terminal"
        default: return "doc.text"
        }
    }

    func load() async {
        do { listing = try await app.client.get("/api/projects/\(projectId)/files", ["path": dir], as: DirListing.self); error = nil }
        catch { self.error = error.localizedDescription }
        if let st = try? await app.client.get("/api/projects/\(projectId)/git/status", as: GitStatus.self) {
            var m: [String: String] = [:]
            for f in st.files ?? [] {
                m[f.path] = f.code
                var parent = (f.path as NSString).deletingLastPathComponent
                while !parent.isEmpty { if m[parent] == nil { m[parent] = "•" }; parent = (parent as NSString).deletingLastPathComponent }
            }
            gitFiles = m
        }
    }
    func search() async {
        guard !query.isEmpty else { return }
        results = (try? await app.client.get("/api/projects/\(projectId)/search", ["q": query, "mode": searchMode], as: SearchResponse.self).results) ?? []
    }
    func op(_ f: @escaping () async throws -> Void) { Task { do { try await f(); error = nil } catch { self.error = error.localizedDescription }; await load() } }

    func share(_ e: FileEntry) {
        Task {
            guard let d = try? await app.client.data("/api/projects/\(projectId)/raw", ["path": e.path]) else { return }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(e.name)
            try? d.write(to: url)
            let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            if let root = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first?.rootViewController {
                vc.popoverPresentationController?.sourceView = root.view
                vc.popoverPresentationController?.sourceRect = CGRect(x: root.view.bounds.midX, y: root.view.bounds.midY, width: 1, height: 1)
                root.present(vc, animated: true)
            }
        }
    }
}

/// Shows the open file: editor, rendered views, live revisions and diffs.
struct FileViewerPanel: View {
    let projectId: String
    @Environment(AppModel.self) private var app
    @State private var files = FilesState.shared
    @State private var content: FileContent?
    @State private var text = ""
    @State private var baseSha: String?
    @State private var mode = "edit"
    @State private var revisions: [Revision] = []
    @State private var diff: String?
    @State private var conflict: ConflictBox?
    @State private var status: String?
    @State private var changedOnServer = false
    @State private var follow = true

    var path: String? { files.openPath[projectId] }
    var dirty: Bool { content?.text != nil && text != content?.text }

    var body: some View {
        VStack(spacing: 0) {
            if let path {
                header(path)
                if changedOnServer {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Theme.blue)
                        Text(dirty ? "Changed on the server while you were editing." : "Updated on the server.").font(Theme.caption)
                        Spacer()
                        if dirty { Button("Compare") { Task { await save(force: false) } }.font(Theme.label) }
                        Button(dirty ? "Discard mine & reload" : "Reload") { Task { await load() } }.font(Theme.label)
                    }
                    .padding(.horizontal, 10).frame(height: 30).background(Theme.blue.opacity(0.12))
                }
                bodyView(path)
                if let status { Text(status).font(Theme.caption).foregroundStyle(Theme.textDim).padding(4) }
            } else {
                EmptyNote(icon: "doc.text", text: "Open a file", detail: "Files that agents change are marked live; open one to watch it evolve.")
            }
        }
        .background(Theme.surface)
        .task(id: "\(projectId)/\(path ?? "")") { await load() }
        .onChange(of: app.eventTick) { _, _ in
            guard let e = app.liveEvents.last, e.project == projectId, let p = path,
                  let ep = e.detail?["path"]?.string, ep == p || app.locate(ep)?.rel == p,
                  e.kind == "file.changed" || e.kind == "file.saved" else { return }
            Task {
                await loadRevisions()
                if e.kind == "file.saved" && e.detail?["sha"]?.string == baseSha { return }
                if !dirty && follow { await load(keepMode: true) } else { changedOnServer = true }
            }
        }
        .sheet(item: $conflict) { box in
            ConflictSheet(mine: text, theirs: box.result.currentText ?? "", path: path ?? "") { choice in
                switch choice {
                case .keepMine: baseSha = box.result.currentSha; conflict = nil; Task { await save(force: false) }
                case .takeTheirs: conflict = nil; Task { await load() }
                case .cancel: conflict = nil
                }
            }
        }
    }

    func header(_ path: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text").foregroundStyle(Theme.textDim)
            Text(path).font(Theme.monoSmall).lineLimit(1).truncationMode(.head)
            if dirty { Circle().fill(Theme.accent).frame(width: 7, height: 7).help("Unsaved changes") }
            Spacer()
            Picker("", selection: $mode) {
                Text("Edit").tag("edit"); Text("View").tag("view"); Text("Changes").tag("diff"); Text("History").tag("history")
            }.pickerStyle(.segmented).frame(width: 300)
            Toggle(isOn: $follow) { Image(systemName: "dot.radiowaves.left.and.right") }.toggleStyle(.button).help("Reload automatically when an agent changes this file")
            Button { Task { await save(force: false) } } label: { Text("Save").font(Theme.label).padding(.horizontal, 10).frame(height: 28).background(dirty ? Theme.accent : Theme.hover, in: RoundedRectangle(cornerRadius: 6)).foregroundStyle(dirty ? .black : Theme.textDim) }
                .buttonStyle(.plain).disabled(!dirty).keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 10).frame(height: 38).background(Theme.raised)
    }

    @ViewBuilder func bodyView(_ path: String) -> some View {
        let ext = (path as NSString).pathExtension.lowercased()
        if let c = content, c.binary || c.tooLarge == true {
            if ["png", "jpg", "jpeg", "gif", "webp"].contains(ext) {
                AuthImage(path: "/api/projects/\(projectId)/raw", query: ["path": path]).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(Theme.terminalBg))
            } else if ["mp4", "mov", "m4v", "webm"].contains(ext) {
                VideoPlayerView(url: app.client.url("/api/projects/\(projectId)/raw", ["path": path]), token: app.client.token)
            } else if ext == "pdf" {
                PDFFromGateway(projectId: projectId, path: path)
            } else {
                EmptyNote(icon: "doc.zipper", text: c.tooLarge == true ? "File too large to open here" : "Binary file", detail: Fmt.bytes(c.size))
            }
        } else if content == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch mode {
            case "view":
                if ext == "md" { ScrollView { Text(LocalizedStringKey(text)).font(.system(size: 14)).textSelection(.enabled).frame(maxWidth: 760, alignment: .leading).padding(20) } }
                else if ext == "json" { CodeView(text: prettyJSON(text), path: path) }
                else { CodeView(text: text, path: path, scrollTo: files.jumpLine) }
            case "diff":
                DiffView(diff: diff ?? "", emptyText: "No uncommitted changes against git HEAD").task(id: content?.sha) { await loadDiff() }
            case "history":
                RevisionHistory(projectId: projectId, path: path, revisions: revisions)
            default:
                CodeEditor(text: $text, path: path, fontSize: 13) { Task { await save(force: false) } }
            }
        }
    }

    func load(keepMode: Bool = false) async {
        guard let path else { return }
        changedOnServer = false
        do {
            let c = try await app.client.get("/api/projects/\(projectId)/file", ["path": path], as: FileContent.self)
            content = c; text = c.text ?? ""; baseSha = c.sha; status = nil
            if !keepMode, ["md"].contains((path as NSString).pathExtension.lowercased()) { mode = "view" }
        } catch { status = error.localizedDescription; content = nil }
        await loadRevisions()
    }
    func loadRevisions() async { revisions = (try? await app.client.get("/api/projects/\(projectId)/revisions", ["path": path], as: [Revision].self)) ?? [] }
    func loadDiff() async { diff = (try? await app.client.get("/api/projects/\(projectId)/git/diff", ["file": path], as: DiffResponse.self).diff) ?? "" }

    func save(force: Bool) async {
        guard let path else { return }
        do {
            var body: [String: Any] = ["path": path, "text": text, "force": force]
            if let baseSha { body["baseSha"] = baseSha }
            let r = try await app.client.send("PUT", "/api/projects/\(projectId)/file", body, as: SaveResult.self)
            baseSha = r.sha; content = FileContent(path: path, size: Double(text.utf8.count), mtime: Date().timeIntervalSince1970 * 1000, mime: content?.mime ?? "text/plain", text: text, binary: false, sha: r.sha, tooLarge: false)
            changedOnServer = false; status = "Saved"
        } catch let e as GatewayError where e.isConflict {
            conflict = e.decode(SaveResult.self).map { ConflictBox(result: $0) }
        } catch { status = error.localizedDescription }
    }

    func prettyJSON(_ s: String) -> String {
        guard let d = s.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d), let p = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) else { return s }
        return String(data: p, encoding: .utf8) ?? s
    }
}

struct ConflictBox: Identifiable { let id = UUID(); let result: SaveResult }

struct ConflictSheet: View {
    enum Choice { case keepMine, takeTheirs, cancel }
    let mine: String
    let theirs: String
    let path: String
    let resolve: (Choice) -> Void
    var diff: String { unified(theirs, mine) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This file changed on the server").font(Theme.title)
            Text("Someone (probably an agent) saved \(path) after you opened it. Red lines are theirs, green are yours.").font(Theme.caption).foregroundStyle(Theme.textDim)
            DiffView(diff: diff).frame(maxHeight: .infinity).background(Theme.surface)
            HStack {
                Button("Cancel") { resolve(.cancel) }
                Spacer()
                Button("Take the server version") { resolve(.takeTheirs) }
                Button("Overwrite with mine") { resolve(.keepMine) }.buttonStyle(.borderedProminent)
            }
        }
        .padding(16).background(Theme.bg)
    }
    func unified(_ a: String, _ b: String) -> String {
        let al = a.components(separatedBy: "\n"), bl = b.components(separatedBy: "\n")
        let d = bl.difference(from: al)
        var removed = Set<Int>(), inserted = Set<Int>()
        for c in d { switch c { case .remove(let o, _, _): removed.insert(o); case .insert(let o, _, _): inserted.insert(o) } }
        var out = ["--- server/\(path)", "+++ mine/\(path)", "@@ -1,\(al.count) +1,\(bl.count) @@"]
        var i = 0, j = 0
        while i < al.count || j < bl.count {
            if i < al.count && removed.contains(i) { out.append("-" + al[i]); i += 1 }
            else if j < bl.count && inserted.contains(j) { out.append("+" + bl[j]); j += 1 }
            else { if j < bl.count { out.append(" " + bl[j]) }; i += 1; j += 1 }
        }
        return out.joined(separator: "\n")
    }
}

/// Timeline of genuine on-disk revisions of one file, with per-revision diffs.
struct RevisionHistory: View {
    let projectId: String
    let path: String
    let revisions: [Revision]
    @Environment(AppModel.self) private var app
    @State private var selected: Int?
    @State private var diff: String?
    @State private var playing = false

    var body: some View {
        HStack(spacing: 0) {
            List(revisions, selection: $selected) { r in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(Fmt.time(r.ts)).font(Theme.monoSmall)
                        Spacer()
                        if let a = r.added, let d = r.removed { Text("+\(a)").foregroundStyle(Theme.green); Text("−\(d)").foregroundStyle(Theme.red) }
                    }.font(Theme.monoSmall)
                    HStack(spacing: 4) {
                        Image(systemName: r.source == "agent" ? "sparkles" : "internaldrive").font(.system(size: 10.5))
                        Text(r.source == "agent" ? (app.agent(r.session)?.agentName ?? "Agent") : "Disk change").font(.system(size: 12))
                        Text(Fmt.bytes(r.size)).font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
                    }.foregroundStyle(Theme.textDim)
                }
                .tag(r.id).listRowBackground(selected == r.id ? Theme.hover : Theme.surface)
            }
            .listStyle(.plain).scrollContentBackground(.hidden).frame(width: 230)
            .overlay { if revisions.isEmpty { EmptyNote(icon: "clock.arrow.circlepath", text: "No revisions yet", detail: "Open the workspace: while it's watched, every save to this file is snapshotted.") } }
            Divider().overlay(Theme.line)
            VStack(spacing: 0) {
                HStack {
                    Button { play() } label: { Label(playing ? "Playing…" : "Replay edits", systemImage: "play.fill") }.font(Theme.label).disabled(revisions.count < 2 || playing)
                    Text("Steps through the real saved revisions, oldest first.").font(Theme.caption).foregroundStyle(Theme.textFaint)
                    Spacer()
                }.padding(.horizontal, 10).frame(height: 30).background(Theme.raised)
                DiffView(diff: diff ?? "", emptyText: selected == nil ? "Choose a revision" : "First snapshot (nothing earlier to compare)")
            }
        }
        .task(id: selected) {
            guard let s = selected else { return }
            diff = (try? await app.client.get("/api/revisions/\(s)/diff", as: RevisionDiff.self).diff) ?? nil
        }
        .onAppear { if selected == nil { selected = revisions.first?.id } }
    }

    func play() {
        playing = true
        Task {
            for r in revisions.reversed() { selected = r.id; try? await Task.sleep(nanoseconds: 1_400_000_000) }
            playing = false
        }
    }
}

struct VideoPlayerView: View {
    let url: URL
    let token: String?
    @State private var player: AVPlayer?
    var body: some View {
        VideoPlayer(player: player).background(Color(Theme.terminalBg))
            .onAppear {
                let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Bearer \(token ?? "")"]])
                player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            }
            .onDisappear { player?.pause() }
    }
}

struct PDFFromGateway: UIViewRepresentable {
    let projectId: String
    let path: String
    @Environment(AppModel.self) private var app
    func makeUIView(context: Context) -> PDFView {
        let v = PDFView(); v.autoScales = true; v.backgroundColor = .black
        Task { if let d = try? await app.client.data("/api/projects/\(projectId)/raw", ["path": path]) { v.document = PDFDocument(data: d) } }
        return v
    }
    func updateUIView(_ v: PDFView, context: Context) {}
}
