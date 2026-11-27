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
    var matches: [String: [SearchResult]] = [:]
    var tabs: [String: [String]] = [:]
    var drafts: [String: String] = [:]
    var originals: [String: FileContent] = [:]
    var replacePath: [String: String] = [:]
    var restoreTick = 0
    var jumpLine: Int?
    var unsaved: Set<String> = []          // projects whose open file has unsaved edits
    func open(project: String, path: String, line: Int? = nil) {
        if !(tabs[project] ?? []).contains(path) { tabs[project, default: []].append(path) }
        openPath[project] = path
        browsePath[project] = (path as NSString).deletingLastPathComponent
        jumpLine = line
        UserDefaults.standard.set(openPath, forKey: "files.open")
    }
    func close(project: String) {
        openPath[project] = nil
        unsaved.remove(project)
        UserDefaults.standard.set(openPath, forKey: "files.open")
    }
}

struct FilesSectionView: View {
    @Environment(AppModel.self) private var app
    @State private var files = FilesState.shared
    @State private var confirmClose: String?
    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ProjectPicker(selection: $app.filesProject)
                Spacer()
                if let p = app.filesProject {
                    Button { app.openGitBuilds(project: p) } label: {
                        Label("Git & Builds", systemImage: "arrow.triangle.branch")
                            .font(.system(size: 12.5, weight: .medium))
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.text)
                }
            }
            .padding(8).background(Theme.raised)
            if let p = app.filesProject {
                // Phone: the browser, then the open file full screen with Back.
                AdaptiveSplit(masterWidth: 300, showingDetail: files.openPath[p] != nil, backTitle: "Files",
                              onBack: {
                    if files.unsaved.contains(p) { confirmClose = p } else { withAnimation(.snappy(duration: 0.22)) { files.close(project: p) } }
                }) {
                    FileBrowser(projectId: p)
                } detail: {
                    FileViewerPanel(projectId: p)
                }
            } else { EmptyNote(icon: "folder", text: "Choose a project") }
        }
        .background(Theme.bg)
        .confirmationDialog("Discard unsaved changes?", isPresented: Binding(get: { confirmClose != nil }, set: { if !$0 { confirmClose = nil } }), titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { if let p = confirmClose { withAnimation(.snappy(duration: 0.22)) { files.close(project: p) } } }
        } message: { Text("Your edits to this file haven't been saved to the server.") }
        .onAppear { if app.filesProject == nil { app.filesProject = app.workspaceProject ?? app.projects.first?.id } }
        .onChange(of: app.projects.count) { _, _ in if app.filesProject == nil { app.filesProject = app.workspaceProject ?? app.projects.first?.id } }
    }
}

struct FileBrowser: View {
    let projectId: String
    var onOpen: () -> Void = {}
    @Environment(AppModel.self) private var app
    @State private var files = FilesState.shared
    @State private var listing: DirListing?
    @State private var expanded: Set<String> = []
    @State private var children: [String: [FileEntry]] = [:]
    @AppStorage("manual.favourites") private var favouriteData = ""
    @State private var creating = false
    @State private var createPath = ""
    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var selectedPaths: Set<String> = []
    @State private var copyStatus: String?
    @State private var searching = false
    @State private var searchMode = "name"
    @State private var regex = false
    @State private var caseSensitive = false
    @State private var wholeWord = false
    @State private var includeIgnored = false
    @State private var folderFilter = ""
    @State private var extensionFilter = ""
    @AppStorage("manual.recentSearch") private var recentSearch = ""
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
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.textFaint)
                TextField(searchMode == "name" ? "Find file" : searchMode == "content" ? "Search in files" : searchMode == "symbols" ? "Find symbol" : "Find command", text: $query)
                    .font(.system(size: 13)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit { Task { await search() } }
                Menu {
                    Picker("Search", selection: $searchMode) { Text("File names").tag("name"); Text("File contents").tag("content"); Text("Symbols").tag("symbols"); Text("Commands").tag("commands") }
                    Section("Options") {
                        Toggle("Regular expression", isOn: $regex)
                        Toggle("Case sensitive", isOn: $caseSensitive)
                        Toggle("Whole word", isOn: $wholeWord)
                        Toggle("Include ignored files", isOn: $includeIgnored)
                    }
                    if !recentSearch.isEmpty { Button("Reuse last search: \(recentSearch)") { query = recentSearch } }
                } label: {
                    Image(systemName: regex || caseSensitive || wholeWord || includeIgnored || searchMode != "name" ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        .font(.system(size: 14)).foregroundStyle(Theme.textDim).frame(width: 28, height: 28)
                }
                .accessibilityLabel("Search options")
            }
            .padding(.horizontal, 8).frame(height: 32)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 8).padding(.bottom, 4)
            if searchMode == "content" && !query.isEmpty {
                HStack {
                    TextField("In folder", text: $folderFilter)
                    TextField("Extension", text: $extensionFilter)
                }.font(Theme.caption).textInputAutocapitalization(.never).autocorrectionDisabled().padding(.horizontal, 10).padding(.bottom, 4)
            }
            if searchMode == "commands" {
                List {
                    ForEach(["Copy Entire File", "Copy Path", "Replace File", "Reveal in Explorer"].filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }, id: \.self) { command in
                        Button(command) {
                            guard let path = files.openPath[projectId] else { return }
                            switch command {
                            case "Copy Entire File": copyFiles([path])
                            case "Copy Path": UIPasteboard.general.string = path
                            case "Replace File": files.replacePath[projectId] = path; files.restoreTick += 1
                            default: files.browsePath[projectId] = (path as NSString).deletingLastPathComponent; query = ""; searchMode = "name"
                            }
                        }
                    }
                }
            } else if !query.isEmpty {
                HStack {
                    Button("Copy selected (\(selectedPaths.count))") { copyFiles(selectedPaths.sorted()) }
                        .disabled(selectedPaths.isEmpty)
                    Spacer()
                    if let copyStatus { Text(copyStatus).font(Theme.caption) }
                }.padding(8)
                List {
                    ForEach(Array(Set(results.map(\.path))).sorted(), id: \.self) { path in
                        Section {
                            ForEach(results.filter { $0.path == path }, id: \.self) { r in
                                Button { files.open(project: projectId, path: r.path, line: r.line); onOpen() } label: {
                                    Text(highlight("\(r.line ?? 0): \(r.text ?? r.path)"))
                                        .font(Theme.monoSmall).lineLimit(3)
                                }.buttonStyle(.plain)
                            }
                        } header: {
                            HStack {
                                Button {
                                    if selectedPaths.contains(path) { selectedPaths.remove(path) }
                                    else { selectedPaths.insert(path) }
                                } label: { Image(systemName: selectedPaths.contains(path) ? "checkmark.circle.fill" : "circle") }
                                Text("\(path) (\(results.filter { $0.path == path }.count))").textCase(nil)
                                Spacer()
                                Menu {
                                    Button("Open") { files.open(project: projectId, path: path); onOpen() }
                                    Button("Replace file") {
                                        files.replacePath[projectId] = path
                                        files.open(project: projectId, path: path)
                                        files.restoreTick += 1; onOpen()
                                    }
                                    Button("Copy entire file") { copyFiles([path]) }
                                    Button("Copy path") { UIPasteboard.general.string = path }
                                    Button("Copy matching lines") {
                                        UIPasteboard.general.string = results.filter { $0.path == path }.map { "\($0.path):\($0.line ?? 0): \($0.text ?? "")" }.joined(separator: "\n")
                                    }
                                } label: { Image(systemName: "ellipsis.circle") }
                            }
                        }
                    }
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
                .overlay { if results.isEmpty { Text(searching ? "Searching…" : "No results").font(Theme.caption).foregroundStyle(Theme.textFaint) } }
            } else {
                breadcrumb
                List {
                    ForEach(favouriteData.components(separatedBy: "\n").filter { $0.hasPrefix(projectId + ":") }, id: \.self) { item in
                        let path = String(item.dropFirst(projectId.count + 1))
                        Button { files.open(project: projectId, path: path) } label: { Label(path, systemImage: "star.fill") }
                    }
                    ForEach((listing?.entries ?? []).filter { showHidden || !($0.hidden ?? false) }) { e in treeRow(e, depth: 0) }
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
                .refreshable { await load() }
            }
            if let error { Text(error).font(Theme.caption).foregroundStyle(Theme.red).padding(6) }
        }
        .background(Theme.surface)
        .task(id: "\(projectId)/\(dir)") { await load() }
        .task(id: "\(projectId)|\(query)|\(searchMode)|\(regex)|\(caseSensitive)|\(wholeWord)|\(includeIgnored)|\(folderFilter)|\(extensionFilter)") {
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                await search()
            } catch {}
        }
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
        .alert("New file", isPresented: $creating) {
            TextField("Relative path", text: $createPath)
            Button("Create") {
                op {
                    _ = try await app.client.send("PUT", "/api/projects/\(projectId)/file", ["path": createPath, "text": ""], as: SaveResult.self)
                    files.open(project: projectId, path: createPath)
                }
            }
            Button("Cancel", role: .cancel) {}
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
                Button("New file") { createPath = dir.isEmpty ? "" : dir + "/"; creating = true }
                Button { importing = true } label: { Label("Upload files", systemImage: "square.and.arrow.up") }
                Button { op { _ = try await app.client.send("POST", "/api/projects/\(projectId)/mkdir", ["path": (dir.isEmpty ? "" : dir + "/") + "new-folder"], as: [String: String].self) } } label: { Label("New folder", systemImage: "folder.badge.plus") }
                Toggle("Show hidden files", isOn: $showHidden)
            } label: { Image(systemName: "ellipsis.circle").frame(width: 28, height: 28) }
        }
        .font(Theme.caption).foregroundStyle(Theme.textDim).padding(.horizontal, 10).frame(height: 30)
    }

    func treeRow(_ entry: FileEntry, depth: Int) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 0) {
            row(entry).padding(.leading, CGFloat(depth) * 14)
            if expanded.contains(entry.path) {
                ForEach((children[entry.path] ?? []).filter { showHidden || !($0.hidden ?? false) }) { child in
                    treeRow(child, depth: depth + 1)
                }
            }
        })
    }

    @ViewBuilder func row(_ e: FileEntry) -> some View {
        Button {
            if e.dir {
                if expanded.contains(e.path) { expanded.remove(e.path) }
                else {
                    expanded.insert(e.path)
                    Task {
                        do { children[e.path] = try await app.client.get("/api/projects/\(projectId)/files", ["path": e.path], as: DirListing.self).entries }
                        catch { self.error = error.localizedDescription }
                    }
                }
            } else { files.open(project: projectId, path: e.path); onOpen() }
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
            if !e.dir {
                Button("Copy entire file") { copyFiles([e.path]) }
                Button("Favourite") {
                    let item = projectId + ":" + e.path
                    var items = Set(favouriteData.components(separatedBy: "\n").filter { !$0.isEmpty })
                    if items.contains(item) { items.remove(item) } else { items.insert(item) }
                    favouriteData = items.sorted().joined(separator: "\n")
                }
            }
            Button("Reveal in folder") { files.browsePath[projectId] = e.dir ? e.path : (e.path as NSString).deletingLastPathComponent }
            Button { renaming = e; newName = e.path } label: { Label("Rename / move", systemImage: "pencil") }
            Button { op { _ = try await app.client.send("POST", "/api/projects/\(projectId)/move", ["from": e.path, "to": e.path + "-copy", "copy": true], as: [String: String].self) } } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            if !e.dir { Button { share(e) } label: { Label("Download / share", systemImage: "square.and.arrow.down") } }
            Button { UIPasteboard.general.string = e.path } label: { Label("Copy path", systemImage: "doc.on.doc") }
            Button(role: .destructive) { deleting = e } label: { Label("Delete…", systemImage: "trash") }
        }
    }

    func highlight(_ value: String) -> AttributedString {
        var result = AttributedString(value)
        if !query.isEmpty {
            var options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
            if regex { options.insert(.regularExpression) }
            var remaining = value.startIndex..<value.endIndex
            while let range = value.range(of: query, options: options, range: remaining), !range.isEmpty {
                if let lower = AttributedString.Index(range.lowerBound, within: result),
                   let upper = AttributedString.Index(range.upperBound, within: result) {
                    result[lower..<upper].backgroundColor = Theme.yellow.opacity(0.3)
                }
                remaining = range.upperBound..<value.endIndex
            }
        }
        return result
    }

    func copyFiles(_ paths: [String]) {
        Task {
            do {
                var chunks: [String] = []
                for path in paths {
                    let file = try await app.client.get("/api/projects/\(projectId)/file", ["path": path], as: FileContent.self)
                    guard let text = file.text, file.tooLarge != true, !file.binary else {
                        copyStatus = "Cannot copy complete text: \(path)"; return
                    }
                    chunks.append(paths.count == 1 ? text : "===== \(path) =====\n" + text + "\n===== End \(path) =====")
                }
                UIPasteboard.general.string = chunks.joined(separator: "\n\n")
                copyStatus = "Copied \(paths.count) file(s)"
            } catch { copyStatus = error.localizedDescription }
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
        guard !query.isEmpty, searchMode != "commands" else { return }
        searching = true
        defer { if !Task.isCancelled { searching = false } }
        do {
            let response = try await app.client.get("/api/projects/\(projectId)/search", ["q": query, "mode": searchMode, "regex": String(regex), "caseSensitive": String(caseSensitive), "wholeWord": String(wholeWord), "includeIgnored": String(includeIgnored), "folder": folderFilter, "extension": extensionFilter], as: SearchResponse.self)
            guard !Task.isCancelled else { return }
            results = response.results; files.matches[projectId] = response.results; error = nil; recentSearch = query
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
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
    @State private var replacing = false
    @State private var replacement = ""
    @State private var previewReplacement = false
    @State private var jump = ""
    @State private var showJump = false
    @State private var wordWrap = true
    @Environment(\.compactLayout) private var compact

    var path: String? { files.openPath[projectId] }
    var dirty: Bool { content?.text != nil && text != content?.text }

    func closeTab(_ tab: String) {
        guard files.drafts[projectId + "/" + tab] == nil || tab != path || !dirty else { status = "Save or revert before closing"; return }
        files.tabs[projectId]?.removeAll { $0 == tab }
        if tab == path { if let next = files.tabs[projectId]?.last { files.open(project: projectId, path: next) } else { files.close(project: projectId) } }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let path {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(files.tabs[projectId] ?? [path], id: \.self) { tab in
                            let on = tab == path
                            HStack(spacing: 5) {
                                Image(systemName: "doc.text").font(.system(size: 10)).foregroundStyle(on ? Theme.accent : Theme.textFaint)
                                Text((tab as NSString).lastPathComponent).font(.system(size: 12, weight: on ? .semibold : .regular)).lineLimit(1)
                                if files.drafts[projectId + "/" + tab] != nil { Circle().fill(Theme.textDim).frame(width: 6, height: 6) }
                                if (files.tabs[projectId]?.count ?? 0) > 1 {
                                    Button { closeTab(tab) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 16, height: 16) }
                                        .buttonStyle(.plain).foregroundStyle(Theme.textFaint).accessibilityLabel("Close \((tab as NSString).lastPathComponent)")
                                }
                            }
                            .padding(.horizontal, 10).frame(height: 28)
                            .background(on ? Theme.surface : Theme.bg)
                            .overlay(alignment: .top) { if on { Rectangle().fill(Theme.accent).frame(height: 2) } }
                            .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
                            .contentShape(Rectangle())
                            .onTapGesture { files.open(project: projectId, path: tab) }
                            .foregroundStyle(on ? Theme.text : Theme.textDim)
                        }
                    }
                }
                .background(Theme.bg)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
                header(path)
                    .onChange(of: dirty) { _, d in if d { files.unsaved.insert(projectId) } else { files.unsaved.remove(projectId) } }
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
        .onChange(of: text) { _, value in
            guard let content, let path, content.path == path else { return }
            let key = projectId + "/" + path
            files.originals[key] = content
            files.drafts[key] = value == content.text ? nil : value
        }
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
        .onChange(of: files.restoreTick) { _, _ in Task { mode = "edit"; await load() } }
        .alert("Jump to line", isPresented: $showJump) {
            TextField("Line number", text: $jump).keyboardType(.numberPad)
            Button("Go") { if let line = Int(jump), line > 0 { files.jumpLine = line; mode = "edit" } }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $replacing) {
            VStack {
                Text("Replace File").font(Theme.title)
                Button("Paste replacement") {
                    if let pasted = UIPasteboard.general.string { replacement = pasted }
                }
                if previewReplacement {
                    DiffView(diff: ConflictSheet(mine: replacement, theirs: text, path: path ?? "", resolve: { _ in }).diff)
                } else {
                    TextEditor(text: $replacement).font(Theme.monoSmall)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                HStack {
                    Button("Cancel") { replacing = false }
                    Button(previewReplacement ? "Edit" : "Preview changes") { previewReplacement.toggle() }
                    Spacer()
                    Button(previewReplacement ? "Save" : "Quick Save") {
                        text = replacement; replacing = false
                        Task { await save(force: false) }
                    }
                }
            }.padding()
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
            Text(compact ? (path as NSString).lastPathComponent : path).font(Theme.monoSmall).lineLimit(1).truncationMode(.head)
            if !(files.matches[projectId] ?? []).isEmpty {
                Button { navigateMatch(-1) } label: { Image(systemName: "chevron.up") }.accessibilityLabel("Previous match")
                Button { navigateMatch(1) } label: { Image(systemName: "chevron.down") }.accessibilityLabel("Next match")
            }
            if dirty { Circle().fill(Theme.accent).frame(width: 7, height: 7).help("Unsaved changes") }
            Spacer()
            if compact {
                Menu {
                    Picker("Mode", selection: $mode) { ForEach(Self.modes, id: \.self) { m in Text(Self.modeTitle(m)).tag(m) } }
                    Toggle(isOn: $follow) { Label("Reload when an agent changes it", systemImage: "dot.radiowaves.left.and.right") }
                } label: {
                    HStack(spacing: 3) { Text(Self.modeTitle(mode)).font(Theme.label); Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)) }
                        .padding(.horizontal, 8).frame(height: 28).background(Theme.hover, in: RoundedRectangle(cornerRadius: 6))
                }
            } else {
                Picker("", selection: $mode) { ForEach(Self.modes, id: \.self) { m in Text(Self.modeTitle(m)).tag(m) } }.pickerStyle(.segmented).frame(width: 300)
                Toggle(isOn: $follow) { Image(systemName: "dot.radiowaves.left.and.right") }.toggleStyle(.button).help("Reload automatically when an agent changes this file")
            }
            Button {
                UIPasteboard.general.string = text; status = "Copied entire file"
            } label: { Image(systemName: "doc.on.doc") }
                .accessibilityLabel("Copy entire file").disabled(content?.text == nil)
            Menu {
                Toggle("Word wrap", isOn: $wordWrap)
                Button("Jump to line") { showJump = true }.keyboardShortcut("l", modifiers: .command)
                Button("Close tab") {
                    guard !dirty else { status = "Save your changes before closing this tab"; return }
                    files.tabs[projectId]?.removeAll { $0 == path }
                    if let next = files.tabs[projectId]?.last { files.open(project: projectId, path: next) }
                    else { files.close(project: projectId) }
                }.keyboardShortcut("w", modifiers: .command)
                Button("Copy path") { UIPasteboard.general.string = path }
                Button("Copy filename") { UIPasteboard.general.string = (path as NSString).lastPathComponent }
                Button("Copy with filename") { UIPasteboard.general.string = path + "\n\n" + text }
                Button("Reveal in folder") { files.browsePath[projectId] = (path as NSString).deletingLastPathComponent }
            } label: { Image(systemName: "ellipsis.circle") }
            Button {
                replacement = text; previewReplacement = false; replacing = true
            } label: { Image(systemName: "arrow.triangle.2.circlepath.doc.on.clipboard") }
                .accessibilityLabel("Replace file").disabled(content?.text == nil)
            Button { Task { await save(force: false) } } label: { Text("Save").font(Theme.label).padding(.horizontal, 10).frame(height: 28).background(dirty ? Theme.accent : Theme.hover, in: RoundedRectangle(cornerRadius: 6)).foregroundStyle(dirty ? .black : Theme.textDim) }
                .buttonStyle(.plain).disabled(!dirty).keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 10).frame(height: 38).background(Theme.raised)
    }

    func navigateMatch(_ direction: Int) {
        let matches = files.matches[projectId] ?? []
        guard !matches.isEmpty else { return }
        let current = matches.firstIndex { $0.path == path && $0.line == files.jumpLine } ?? 0
        let next = matches[(current + direction + matches.count) % matches.count]
        files.open(project: projectId, path: next.path, line: next.line)
        mode = "edit"
    }

    static let modes = ["edit", "view", "diff", "history"]
    static func modeTitle(_ m: String) -> String { ["edit": "Edit", "view": "View", "diff": "Changes", "history": "History"][m] ?? m.capitalized }

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
                CodeEditor(text: $text, path: path, fontSize: 13, jumpLine: files.jumpLine, wordWrap: wordWrap) { Task { await save(force: false) } }.id(path)
            }
        }
    }

    func load(keepMode: Bool = false) async {
        guard let path else { return }
        let key = projectId + "/" + path
        if let draft = files.drafts[key], let original = files.originals[key] {
            content = original; text = draft; baseSha = original.sha
            prepareReplacement(path)
            return
        }
        changedOnServer = false
        do {
            let c = try await app.client.get("/api/projects/\(projectId)/file", ["path": path], as: FileContent.self)
            guard !Task.isCancelled, self.path == path else { return }
            content = c; text = c.text ?? ""; baseSha = c.sha; status = nil
            if !keepMode { mode = "edit" }
            if !keepMode, ["md"].contains((path as NSString).pathExtension.lowercased()) { mode = "view" }
        } catch { status = error.localizedDescription; content = nil }
        prepareReplacement(path)
        await loadRevisions()
    }
    func prepareReplacement(_ path: String) {
        if files.replacePath[projectId] == path, content?.text != nil {
            files.replacePath[projectId] = nil; replacement = text; previewReplacement = false; replacing = true
        }
    }
    func loadRevisions() async { revisions = (try? await app.client.get("/api/projects/\(projectId)/revisions", ["path": path], as: [Revision].self)) ?? [] }
    func loadDiff() async { diff = (try? await app.client.get("/api/projects/\(projectId)/git/diff", ["file": path], as: DiffResponse.self).diff) ?? "" }

    func save(force: Bool) async {
        guard let path, content?.path == path, baseSha != nil else { return }
        let savedText = text
        do {
            var body: [String: Any] = ["path": path, "text": savedText, "force": force]
            if let baseSha { body["baseSha"] = baseSha }
            let r = try await app.client.send("PUT", "/api/projects/\(projectId)/file", body, as: SaveResult.self)
            guard self.path == path else { return }
            baseSha = r.sha; content = FileContent(path: path, size: Double(savedText.utf8.count), mtime: Date().timeIntervalSince1970 * 1000, mime: content?.mime ?? "text/plain", text: savedText, binary: false, sha: r.sha, tooLarge: false)
            files.drafts[projectId + "/" + path] = text == savedText ? nil : text
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

struct RevisionText: Decodable { let text: String; let path: String }

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
    @Environment(\.compactLayout) private var compact

    var body: some View {
        let stack = compact ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        stack {
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
            .listStyle(.plain).scrollContentBackground(.hidden).frame(width: compact ? nil : 230, height: compact ? 170 : nil)
            .overlay { if revisions.isEmpty { EmptyNote(icon: "clock.arrow.circlepath", text: "No revisions yet", detail: "Open the workspace: while it's watched, every save to this file is snapshotted.") } }
            Divider().overlay(Theme.line)
            VStack(spacing: 0) {
                HStack {
                    Button { play() } label: { Label(playing ? "Playing…" : "Replay edits", systemImage: "play.fill") }.font(Theme.label).disabled(revisions.count < 2 || playing)
                    if !compact { Text("Steps through the real saved revisions, oldest first.").font(Theme.caption).foregroundStyle(Theme.textFaint) }
                    Spacer()
                    if let selected {
                        Button("Restore to editor") {
                            Task {
                                if let revision = try? await app.client.get("/api/revisions/\(selected)", as: RevisionText.self),
                                   let current = try? await app.client.get("/api/projects/\(projectId)/file", ["path": path], as: FileContent.self) {
                                    let state = FilesState.shared
                                    let key = projectId + "/" + path
                                    state.originals[key] = current
                                    state.drafts[key] = revision.text
                                    state.open(project: projectId, path: path)
                                    state.restoreTick += 1
                                }
                            }
                        }
                    }
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
