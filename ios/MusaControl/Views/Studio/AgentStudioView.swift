import SwiftUI

private typealias M = StudioMetrics

extension Agent {
    var tint: Color { agent == "claude" ? Theme.accent : Theme.blue }
    var shortName: String { agent == "claude" ? "Claude" : "Codex" }
}

/// An agent's live desk: tap an agent in the sidebar to watch it work.
/// The cursor, the files it opens, the lines it types and the commands it
/// runs are its real transcript events, replayed as they happen.
struct AgentStudioView: View {
    let agentId: String
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var director: StudioDirector?

    var agent: Agent? { app.agent(agentId) }

    var body: some View {
        VStack(spacing: 0) {
            if let d = director {
                StudioHeader(agentId: agentId, agent: agent, director: d)
                StudioStage(director: d, agent: agent)
                StudioTicker(d: d)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let agent { AgentComposer(agent: agent) }
        }
        .background(Theme.bg)
        .task(id: agentId) {
            let d = StudioDirector(agentId: agentId, client: app.client)
            d.reduceMotion = reduceMotion
            let model = app
            d.locator = { [weak model] path in model?.locate(path) }
            director = d
            let a = app.agent(agentId)
            await d.start(project: app.project(a?.project), cwd: a?.cwd)
            d.ingest(Array(app.liveEvents.suffix(80)))
        }
        .onChange(of: app.eventTick) { _, _ in director?.ingest(Array(app.liveEvents.suffix(40))) }
        .onDisappear { director?.stop() }
        .accessibilityIdentifier("studio")
    }
}

// MARK: - Header

struct StudioHeader: View {
    let agentId: String
    let agent: Agent?
    let director: StudioDirector
    @Environment(AppModel.self) private var app

    var status: String { agent?.status ?? "ended" }
    var thinking: Bool { !director.busy && status == "working" }

    var captionText: String {
        if director.busy { return director.caption }
        switch status {
        case "working": return "Thinking about the next step"
        case "approval": return "Waiting for your approval"
        case "idle": return "Done for now — waiting for your next instruction"
        default: return "Not running"
        }
    }
    var captionIcon: String {
        if director.busy { return director.captionIcon }
        switch status {
        case "working": return "brain"
        case "approval": return "hand.raised"
        case "idle": return "cup.and.saucer"
        default: return "moon.zzz"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            AgentAvatar(kind: agent?.agent ?? "claude", status: status, size: 42)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let p = app.project(agent?.project) {
                        Text(p.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.accent)
                        Text("·").foregroundStyle(Theme.textFaint)
                    }
                    Text(agent?.agentName ?? "Agent").font(.system(size: 12.5)).foregroundStyle(Theme.textDim)
                    LivePill(mode: director.mode, status: status)
                }
                Text(agent?.title ?? "Agent session").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                HStack(spacing: 6) {
                    Image(systemName: captionIcon).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(status == "approval" ? Theme.yellow : agent?.tint ?? Theme.accent)
                        .symbolEffect(.bounce, value: captionText)
                        .frame(width: 16)
                    Text(captionText).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                        .contentTransition(.interpolate)
                        .id(captionText)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                    if thinking { TypingDots(color: Theme.textDim, size: 4) }
                }
                .animation(.snappy(duration: 0.25), value: captionText)
            }
            Spacer(minLength: 8)
            ViewThatFits(in: .horizontal) {
                stats
                EmptyView()
            }
            buttons.fixedSize()
                .layoutPriority(2)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    var stats: some View {
        HStack(spacing: 12) {
            StatChip(icon: "pencil.line", value: agent?.counts?.edits ?? 0, label: "edits")
            StatChip(icon: "terminal", value: agent?.counts?.commands ?? 0, label: "commands")
            if let s = agent?.startedAt {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Label(Fmt.duration(max(0, ctx.date.timeIntervalSince1970 - s / 1000)), systemImage: "clock")
                        .font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(Theme.textDim)
                }
            }
        }
    }

    var buttons: some View {
        HStack(spacing: 2) {
            if !director.busy {
                IconButton(systemName: "arrow.counterclockwise", help: "Replay the last few actions") { director.replay() }
            }
            if let t = agent?.tmux?.session {
                IconButton(systemName: "terminal", help: "Open its terminal") { app.attachTerminal(t) }
            }
            IconButton(systemName: "list.bullet.rectangle", help: "Full activity log") { app.openAgent(agentId) }
            IconButton(systemName: "xmark", help: "Close") { withAnimation(.snappy(duration: 0.2)) { app.studioAgent = nil } }
                .accessibilityIdentifier("studio.close")
        }
    }
}

struct StatChip: View {
    let icon: String
    let value: Int
    let label: String
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(Theme.textFaint)
            Text("\(value)").font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.text)
                .contentTransition(.numericText(value: Double(value)))
                .animation(.snappy, value: value)
        }
        .accessibilityLabel(Text("\(value) \(label)"))
    }
}

struct LivePill: View {
    let mode: StudioDirector.Mode
    let status: String
    @State private var on = false
    var body: some View {
        Group {
            if mode == .catchingUp {
                Label("Replaying recent", systemImage: "backward.fill").foregroundStyle(Theme.purple)
                    .padding(.horizontal, 7).padding(.vertical, 2).background(Theme.purple.opacity(0.14), in: Capsule())
            } else if status == "working" || status == "approval" {
                HStack(spacing: 4) {
                    Circle().fill(Theme.red).frame(width: 6, height: 6).opacity(on ? 0.35 : 1)
                    Text("LIVE").tracking(0.6)
                }
                .foregroundStyle(Theme.red)
                .padding(.horizontal, 7).padding(.vertical, 2).background(Theme.red.opacity(0.12), in: Capsule())
                .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever()) { on = true } }
            } else {
                Text("Quiet").foregroundStyle(Theme.textFaint)
                    .padding(.horizontal, 7).padding(.vertical, 2).background(Theme.raised, in: Capsule())
            }
        }
        .font(.system(size: 10.5, weight: .bold))
        .labelStyle(.titleAndIcon)
    }
}

// MARK: - Stage

struct StudioStage: View {
    let director: StudioDirector
    let agent: Agent?
    var d: StudioDirector { director }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let explorer = w >= 720
            let side = w >= 1020
            ZStack(alignment: .topLeading) {
                StageBackdrop(tint: agent?.tint ?? Theme.accent, active: agent?.status == "working")
                HStack(spacing: 12) {
                    if explorer {
                        ExplorerWindow(d: d)
                            .frame(width: min(250, w * 0.23))
                            .studioRegion(.explorer, d)
                    }
                    VStack(spacing: 12) {
                        EditorWindow(d: d).studioRegion(.editor, d)
                        TerminalWindow(d: d)
                            .frame(height: max(150, geo.size.height * 0.32))
                            .studioRegion(.terminal, d)
                    }
                    if side {
                        VStack(spacing: 12) {
                            ThoughtCard(d: d, agent: agent).studioRegion(.thought, d)
                            if !d.plan.isEmpty { StudioPlanCard(steps: d.plan).transition(.move(edge: .trailing).combined(with: .opacity)) }
                            if !d.photos.isEmpty { PhotoStack(photos: d.photos).transition(.scale.combined(with: .opacity)) }
                        }
                        .frame(width: 272)
                        .animation(.snappy, value: d.plan.isEmpty)
                    }
                }
                .padding(14)

                if !side && (!d.thoughtDone || d.thought.isEmpty && agent?.status == "working") {
                    ThoughtCard(d: d, agent: agent)
                        .frame(width: min(300, w - 60), height: 150)
                        .studioRegion(.thought, d)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.top, 70).padding(.trailing, 28)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }

                if let p = d.heroPhoto {
                    HeroPhoto(photo: p)
                        .frame(width: min(520, w * 0.6))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.scale(scale: 0.3, anchor: .bottomTrailing).combined(with: .opacity))
                        .zIndex(2)
                }

                if let text = d.instruction {
                    InstructionToast(text: text)
                        .frame(maxWidth: min(560, w - 40))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 18)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(3)
                }

                CelebrateBurst(tick: d.celebrateTick)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                StudioCursor(d: d, name: agent?.shortName ?? "Agent", tint: agent?.tint ?? Theme.accent)
                    .zIndex(4)

                if let a = agent, let p = a.approval {
                    VStack {
                        Spacer()
                        ApprovalCard(agent: a, prompt: p)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                            .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
                            .frame(maxWidth: 640)
                            .padding(18)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.14))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(5)
                }
            }
            .coordinateSpace(.named("stage"))
            .onAppear { d.frames[.stage] = CGRect(origin: .zero, size: geo.size); d.showExplorer = explorer }
            .onChange(of: geo.size) { _, s in d.frames[.stage] = CGRect(origin: .zero, size: s) }
            .onChange(of: explorer) { _, e in d.showExplorer = e }
            .animation(.snappy(duration: 0.3), value: agent?.approval != nil)
        }
        .clipped()
    }
}

extension View {
    /// Reports this view's frame on the stage so the director can aim the cursor.
    func studioRegion(_ r: StudioDirector.Region, _ d: StudioDirector) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named("stage")) } action: { d.frames[r] = $0 }
    }
}

struct StageBackdrop: View {
    let tint: Color
    let active: Bool
    var body: some View {
        ZStack {
            Theme.bg
            Canvas { ctx, size in
                let step: CGFloat = 22
                var x: CGFloat = 0
                while x <= size.width {
                    var y: CGFloat = 0
                    while y <= size.height {
                        ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.6, height: 1.6)), with: .color(Theme.textFaint.opacity(0.22)))
                        y += step
                    }
                    x += step
                }
            }
            RadialGradient(colors: [tint.opacity(active ? 0.16 : 0.06), .clear], center: .topLeading, startRadius: 10, endRadius: 520)
                .animation(.easeInOut(duration: 0.8), value: active)
        }
        .ignoresSafeArea()
    }
}

/// A desktop window: title bar with traffic lights, highlighted while the
/// agent's cursor is working inside it.
struct StudioWindow<Accessory: View, Content: View>: View {
    let title: String
    let icon: String
    var dark = false
    var active = false
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Circle().fill(Color(red: 0.98, green: 0.37, blue: 0.34))
                    Circle().fill(Color(red: 0.99, green: 0.74, blue: 0.18))
                    Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25))
                }
                .frame(height: 9).opacity(active ? 0.95 : 0.45)
                Image(systemName: icon).font(.system(size: 11, weight: .medium))
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                accessory
            }
            .foregroundStyle(dark ? Color.white.opacity(0.75) : Theme.textDim)
            .padding(.horizontal, 10)
            .frame(height: M.chrome)
            .background(dark ? Color(white: 0.17) : Theme.raised)
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(dark ? Color(Theme.terminalBg) : Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(active ? Theme.accent.opacity(0.6) : Theme.lineStrong, lineWidth: active ? 1.5 : 1))
        .shadow(color: .black.opacity(active ? 0.16 : 0.08), radius: active ? 14 : 8, y: 4)
        .animation(.easeOut(duration: 0.25), value: active)
    }
}

// MARK: Explorer

struct ExplorerWindow: View {
    let d: StudioDirector
    var body: some View {
        StudioWindow(title: d.rootName, icon: "folder", active: d.focus == .explorer) {
            EmptyView()
        } content: {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                    if let q = d.searchText {
                        Text(q).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.head)
                        BlinkCaret(color: Theme.accent, height: 13)
                    } else {
                        Text("Search").font(.system(size: 12)).foregroundStyle(Theme.textFaint)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9).frame(height: 26)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(d.searchText != nil ? Theme.accent.opacity(0.6) : Theme.line))
                .padding(.horizontal, 8)
                .frame(height: M.explorerSearch)

                ZStack(alignment: .topLeading) {
                    ForEach(Array(d.tree.enumerated()), id: \.element.id) { i, row in
                        TreeRowView(row: row, active: d.activeRow == row.path)
                            .frame(height: M.rowH)
                            .offset(y: CGFloat(i) * M.rowH - d.treeScroll)
                            .transition(.opacity)
                    }
                    if d.tree.isEmpty {
                        Text("Files appear here as the agent opens them").font(Theme.caption).foregroundStyle(Theme.textFaint).padding(12)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
            }
        }
    }
}

func fileGlyph(_ name: String, dir: Bool) -> (String, Color) {
    if dir { return ("folder.fill", Theme.accent.opacity(0.85)) }
    switch (name as NSString).pathExtension.lowercased() {
    case "swift": return ("swift", Color.orange)
    case "js", "mjs", "cjs", "jsx": return ("curlybraces", Theme.yellow)
    case "ts", "tsx": return ("curlybraces", Theme.blue)
    case "py", "gd", "sh": return ("chevron.left.forwardslash.chevron.right", Theme.green)
    case "json", "yml", "yaml", "toml", "plist": return ("gearshape", Theme.purple)
    case "md", "txt": return ("doc.plaintext", Theme.textDim)
    case "png", "jpg", "jpeg", "webp", "gif", "svg": return ("photo", Theme.purple)
    case "html", "css": return ("globe", Theme.red)
    default: return ("doc", Theme.textDim)
    }
}

struct TreeRowView: View {
    let row: TreeRow
    let active: Bool
    var body: some View {
        let g = fileGlyph(row.name, dir: row.dir)
        HStack(spacing: 5) {
            Color.clear.frame(width: CGFloat(row.depth) * 12, height: 1)
            Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Theme.textFaint)
                .rotationEffect(.degrees(row.open ? 90 : 0)).opacity(row.dir ? 1 : 0).frame(width: 10)
            Image(systemName: g.0).font(.system(size: 11)).foregroundStyle(g.1).frame(width: 15)
            Text(row.name).font(.system(size: 12.5, weight: active ? .semibold : .regular)).foregroundStyle(active ? Theme.text : Theme.textDim).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: M.rowH - 3)
        .background(active ? Theme.accent.opacity(0.17) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 6)
        .animation(.easeOut(duration: 0.2), value: row.open)
    }
}

// MARK: Editor

struct EditorWindow: View {
    let d: StudioDirector
    @State private var savedFlash = false

    var body: some View {
        StudioWindow(title: d.openPath.map { ($0 as NSString).lastPathComponent } ?? "Editor", icon: "doc.text", active: d.focus == .editor) {
            if d.modified {
                HStack(spacing: 4) { Circle().fill(Theme.accent).frame(width: 6, height: 6); Text("Editing").font(.system(size: 11, weight: .medium)) }
                    .foregroundStyle(Theme.accent).transition(.opacity)
            } else if savedFlash {
                Label("Saved", systemImage: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.green).transition(.scale.combined(with: .opacity))
            }
        } content: {
            VStack(spacing: 0) {
                tabs
                CodeArea(d: d)
            }
        }
        .onChange(of: d.savedTick) { _, _ in
            withAnimation(.spring(duration: 0.3)) { savedFlash = true }
            Task { try? await Task.sleep(nanoseconds: 1_400_000_000); withAnimation(.easeOut(duration: 0.3)) { savedFlash = false } }
        }
        .animation(.easeOut(duration: 0.2), value: d.modified)
    }

    var tabs: some View {
        HStack(spacing: 0) {
            ForEach(d.tabs, id: \.self) { t in
                let name = (t as NSString).lastPathComponent
                let on = t == d.openPath
                let g = fileGlyph(name, dir: false)
                HStack(spacing: 5) {
                    Image(systemName: g.0).font(.system(size: 10)).foregroundStyle(g.1)
                    Text(name).font(.system(size: 12, weight: on ? .semibold : .regular)).lineLimit(1)
                    if on && d.modified { Circle().fill(Theme.textDim).frame(width: 5, height: 5) }
                }
                .foregroundStyle(on ? Theme.text : Theme.textFaint)
                .padding(.horizontal, 11)
                .frame(maxHeight: .infinity)
                .background(on ? Theme.surface : .clear)
                .overlay(alignment: .top) { if on { Rectangle().fill(Theme.accent).frame(height: 2) } }
                .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .frame(height: M.tabBar)
        .background(Theme.raised.opacity(0.55))
        .clipped()
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

struct CodeArea: View {
    let d: StudioDirector

    var body: some View {
        GeometryReader { geo in
            let count = d.lines.count
            let first = min(count, max(0, Int(d.scrollY / M.lineH) - 12))
            let last = min(count, first + Int(geo.size.height / M.lineH) + 30)
            let path = d.openPath ?? ""
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Theme.raised.opacity(0.35)).frame(width: M.gutter).frame(maxHeight: .infinity)
                if let r = d.readLine {
                    Rectangle().fill(Theme.accent.opacity(0.10))
                        .frame(height: M.lineH * 2)
                        .offset(y: M.codeTop + CGFloat(r) * M.lineH - d.scrollY)
                        .animation(.linear(duration: 0.06), value: r)
                }
                ForEach(Array(zip(first..<last, d.lines[first..<last])), id: \.1.id) { i, line in
                    CodeLineRow(number: i + 1, text: line.text, mark: line.mark, sel: line.sel, path: path, scrollX: d.scrollX)
                        .equatable()
                        .offset(y: M.codeTop + CGFloat(i) * M.lineH - d.scrollY)
                        .transition(.opacity)
                }
                if let c = d.caret, c.line >= first, c.line <= last {
                    let x = M.gutter + M.codePad + CGFloat(c.col) * M.codeCharW - d.scrollX - 1
                    if x >= M.gutter {
                        BlinkCaret(color: Theme.accent, height: M.lineH - 4)
                            .offset(x: x, y: M.codeTop + CGFloat(c.line) * M.lineH - d.scrollY + 2)
                    }
                }
                if count == 0 {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass").font(.system(size: 26, weight: .light)).foregroundStyle(Theme.textFaint)
                        Text(d.editorNote ?? "The agent hasn't opened a file yet").font(Theme.caption).foregroundStyle(Theme.textDim)
                            .multilineTextAlignment(.center).frame(maxWidth: 320)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
                if let q = d.quickOpen {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Theme.textFaint)
                        Text(q.isEmpty ? "Go to file…" : q).font(.system(size: 13.5, design: .monospaced))
                            .foregroundStyle(q.isEmpty ? Theme.textFaint : Theme.text).lineLimit(1)
                        BlinkCaret(color: Theme.accent, height: 15)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).frame(height: 38)
                    .frame(width: min(380, geo.size.width - 40))
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(0.5)))
                    .shadow(color: .black.opacity(0.2), radius: 14, y: 6)
                    .frame(width: geo.size.width)
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .animation(.snappy(duration: 0.2), value: d.quickOpen != nil)
        }
    }
}

struct CodeLineRow: View, Equatable {
    let number: Int
    let text: String
    let mark: EdLine.Mark
    let sel: Range<Int>?
    let path: String
    let scrollX: CGFloat

    var markColor: Color {
        switch mark { case .added: return Theme.green; case .selected: return Theme.blue; case .typing: return Theme.accent; case .none: return .clear }
    }
    var rowBg: Color {
        switch mark { case .added: return Theme.addedBg; case .selected: return Theme.blue.opacity(0.18); case .typing: return Theme.accent.opacity(0.09); case .none: return .clear }
    }

    var body: some View {
        HStack(spacing: 0) {
            Text("\(number)").font(.system(size: 11, design: .monospaced))
                .foregroundStyle(mark == .none ? Theme.textFaint : markColor)
                .frame(width: M.gutter - 8, alignment: .trailing).padding(.trailing, 5)
            Rectangle().fill(markColor).frame(width: 3)
            ZStack(alignment: .leading) {
                if let sel, !sel.isEmpty {
                    Rectangle().fill(Theme.blue.opacity(0.3))
                        .frame(width: CGFloat(sel.count) * M.codeCharW, height: M.lineH - 2)
                        .offset(x: CGFloat(sel.lowerBound) * M.codeCharW)
                }
                Text(SyntaxHighlighter.attributed(text, path: path)).lineLimit(1).fixedSize()
            }
            .offset(x: -scrollX)
            .padding(.leading, M.codePad)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
        .frame(height: M.lineH)
        .background(rowBg)
        .animation(.easeOut(duration: 0.35), value: mark)
    }
}

struct BlinkCaret: View {
    var color: Color = Theme.accent
    var height: CGFloat = 15
    @State private var on = true
    var body: some View {
        Rectangle().fill(color).frame(width: 2, height: height)
            .opacity(on ? 1 : 0.15)
            .onAppear { withAnimation(.easeInOut(duration: 0.55).repeatForever()) { on = false } }
    }
}

// MARK: Terminal

struct TerminalWindow: View {
    let d: StudioDirector

    func color(_ k: TermLine.Kind) -> Color {
        switch k {
        case .command: return Color(red: 0.62, green: 0.86, blue: 0.62)
        case .output: return Color.white.opacity(0.78)
        case .ok: return Color(red: 0.45, green: 0.86, blue: 0.6)
        case .fail: return Color(red: 0.98, green: 0.5, blue: 0.48)
        case .note: return Color.white.opacity(0.4)
        }
    }

    var body: some View {
        StudioWindow(title: "Terminal — \(d.rootName)", icon: "terminal", dark: true, active: d.focus == .terminal) {
            if d.termBusy {
                HStack(spacing: 5) { ProgressView().controlSize(.mini).tint(.white); Text("running").font(.system(size: 11)) }
                    .foregroundStyle(Color.white.opacity(0.7))
            }
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(d.term.suffix(40)) { l in
                    Text(l.text).font(.system(size: 12, design: .monospaced)).foregroundStyle(color(l.kind))
                        .lineLimit(1).truncationMode(.tail)
                        .frame(height: M.termLineH, alignment: .leading)
                        .transition(.opacity)
                }
                HStack(spacing: 0) {
                    (Text(d.prompt).foregroundStyle(Color(red: 0.5, green: 0.75, blue: 1.0)) + Text(d.termTyping ?? "").foregroundStyle(Color.white))
                        .font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.head)
                    if !d.termBusy { BlinkCaret(color: .white.opacity(0.85), height: 13) }
                    Spacer(minLength: 0)
                }
                .frame(height: M.termLineH)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, M.termPad).padding(.bottom, M.termPad)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .clipped()
            .modifier(Shake(animatableData: CGFloat(d.shakeTick)))
            .animation(.linear(duration: 0.45), value: d.shakeTick)
            .overlay(alignment: .topTrailing) {
                if let s = d.stamp {
                    Text(s.text).font(.system(size: 13, weight: .heavy, design: .rounded)).lineLimit(2).multilineTextAlignment(.center)
                        .foregroundStyle(s.ok ? Theme.green : Theme.red)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(s.ok ? Theme.green : Theme.red, lineWidth: 2.5))
                        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                        .rotationEffect(.degrees(-7))
                        .frame(maxWidth: 260)
                        .padding(14)
                        .transition(.scale(scale: 2.2).combined(with: .opacity))
                        .id(s.id)
                }
            }
        }
    }
}

struct Shake: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 7 * sin(animatableData * .pi * 4), y: 0))
    }
}

// MARK: Side cards

struct ThoughtCard: View {
    let d: StudioDirector
    let agent: Agent?
    var thinking: Bool { !d.busy && agent?.status == "working" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                AgentAvatar(kind: agent?.agent ?? "claude", status: agent?.status ?? "", size: 20)
                Text(!d.thoughtDone ? "Writing" : thinking ? "Thinking" : "Last note").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textDim)
                Spacer()
                if !d.thoughtDone || thinking { TypingDots(color: agent?.tint ?? Theme.accent, size: 4) }
            }
            if d.thought.isEmpty {
                Text(thinking ? "Working out what to do next…" : "Nothing said yet.").font(.system(size: 13)).foregroundStyle(Theme.textFaint)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    (Text(d.thought) + Text(d.thoughtDone ? "" : " ▍").foregroundStyle(agent?.tint ?? Theme.accent))
                        .font(.system(size: 13)).foregroundStyle(Theme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom)
                .scrollIndicators(.hidden)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(!d.thoughtDone ? (agent?.tint ?? Theme.accent).opacity(0.6) : Theme.lineStrong, lineWidth: !d.thoughtDone ? 1.5 : 1))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
        .animation(.easeOut(duration: 0.25), value: d.thoughtDone)
    }
}

struct StudioPlanCard: View {
    let steps: [PlanStep]
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Plan").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textDim)
                Spacer()
                Text("\(steps.filter { $0.status == "completed" }.count)/\(steps.count)").font(.system(size: 11.5, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.textFaint)
            }
            ProgressView(value: Double(steps.filter { $0.status == "completed" }.count), total: Double(max(steps.count, 1))).tint(Theme.green)
            ForEach(steps.prefix(7)) { s in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Group {
                        switch s.status {
                        case "completed": Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
                        case "in_progress": Image(systemName: "circle.dotted").foregroundStyle(Theme.blue).symbolEffect(.pulse)
                        default: Image(systemName: "circle").foregroundStyle(Theme.textFaint)
                        }
                    }
                    .font(.system(size: 12))
                    .contentTransition(.symbolEffect(.replace))
                    Text(s.text).font(.system(size: 12.5, weight: s.status == "in_progress" ? .semibold : .regular))
                        .foregroundStyle(s.status == "completed" ? Theme.textFaint : Theme.text).lineLimit(2)
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.lineStrong))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
    }
}

struct PhotoStack: View {
    let photos: [StudioPhoto]
    var body: some View {
        ZStack {
            ForEach(Array(photos.enumerated()), id: \.element.id) { i, p in
                Polaroid(photo: p, compact: true)
                    .frame(width: 150)
                    .rotationEffect(.degrees([-7.0, 4.0, -2.0][i % 3]))
                    .offset(x: CGFloat(i) * 28 - 28, y: CGFloat(i) * 6)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 130)
    }
}

struct Polaroid: View {
    let photo: StudioPhoto
    var compact = false
    var body: some View {
        VStack(spacing: compact ? 4 : 8) {
            AuthImage(path: photo.path, query: photo.query, contentMode: .fit)
                .frame(maxHeight: compact ? 90 : 360)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Text(photo.title).font(.system(size: compact ? 9.5 : 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.black.opacity(0.6)).lineLimit(1).truncationMode(.middle)
        }
        .padding(compact ? 6 : 12)
        .background(Color(white: 0.98), in: RoundedRectangle(cornerRadius: 5))
        .shadow(color: .black.opacity(0.25), radius: compact ? 6 : 22, y: compact ? 3 : 10)
    }
}

struct HeroPhoto: View {
    let photo: StudioPhoto
    var body: some View { Polaroid(photo: photo).rotationEffect(.degrees(-2)) }
}

struct InstructionToast: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "person.crop.circle.fill").font(.system(size: 22)).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("New instruction").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.textDim)
                Text(text).font(.system(size: 14)).foregroundStyle(Theme.text).lineLimit(4)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.accent.opacity(0.45)))
        .shadow(color: .black.opacity(0.2), radius: 18, y: 8)
    }
}

// MARK: Cursor & effects

struct ArrowPointer: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: .zero)
        p.addLine(to: CGPoint(x: 0, y: 17))
        p.addLine(to: CGPoint(x: 4.6, y: 13))
        p.addLine(to: CGPoint(x: 7.6, y: 19.6))
        p.addLine(to: CGPoint(x: 10.4, y: 18.4))
        p.addLine(to: CGPoint(x: 7.5, y: 11.9))
        p.addLine(to: CGPoint(x: 13, y: 11.9))
        p.closeSubpath()
        return p
    }
}

struct IBeam: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: -3.5, y: -9)); p.addLine(to: CGPoint(x: 3.5, y: -9))
        p.move(to: CGPoint(x: 0, y: -9)); p.addLine(to: CGPoint(x: 0, y: 9))
        p.move(to: CGPoint(x: -3.5, y: 9)); p.addLine(to: CGPoint(x: 3.5, y: 9))
        return p
    }
}

/// The agent's cursor, multiplayer style: a coloured pointer with a name tag.
struct StudioCursor: View {
    let d: StudioDirector
    let name: String
    let tint: Color

    var body: some View {
        ZStack(alignment: .topLeading) {
            ClickRipple(tick: d.clickTick, color: tint)
            Group {
                switch d.cursorStyle {
                case .arrow:
                    ArrowPointer().fill(tint)
                        .overlay(ArrowPointer().stroke(Color.white, style: StrokeStyle(lineWidth: 1.4, lineJoin: .round)))
                        .frame(width: 14, height: 20, alignment: .topLeading)
                case .ibeam:
                    ZStack {
                        IBeam().stroke(Color.white, style: StrokeStyle(lineWidth: 3.6, lineCap: .round))
                        IBeam().stroke(tint, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    }
                    .frame(width: 0, height: 0)
                case .hand:
                    Image(systemName: "hand.point.up.left.fill").font(.system(size: 20)).foregroundStyle(tint)
                        .shadow(color: .white, radius: 0.5)
                        .offset(x: -4, y: -2)
                }
            }
            .shadow(color: .black.opacity(0.3), radius: 2.5, y: 1.5)
            Text(name).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(tint, in: Capsule())
                .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                .fixedSize()
                .offset(x: 14, y: 20)
        }
        .offset(x: d.cursor.x, y: d.cursor.y)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct ClickRipple: View {
    let tick: Int
    let color: Color
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .keyframeAnimator(initialValue: CGFloat(1), trigger: tick) { _, p in
                Circle().stroke(color, lineWidth: 2.5)
                    .frame(width: 8 + 34 * p, height: 8 + 34 * p)
                    .opacity(p >= 1 ? 0 : Double(1 - p))
                    .frame(width: 0, height: 0)
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(CGFloat(0), duration: 0.01)
                    CubicKeyframe(CGFloat(1), duration: 0.45)
                }
            }
    }
}

struct CelebrateBurst: View {
    let tick: Int
    static let colors: [Color] = [Theme.accent, Theme.green, Theme.blue, Theme.purple, Theme.yellow]
    var body: some View {
        Color.clear.frame(width: 1, height: 1)
            .keyframeAnimator(initialValue: CGFloat(1), trigger: tick) { _, p in
                ZStack {
                    ForEach(0..<18, id: \.self) { i in
                        let a = Double(i) / 18 * 2 * .pi
                        let r = (90 + CGFloat(i % 3) * 30) * p
                        RoundedRectangle(cornerRadius: 1.5).fill(Self.colors[i % Self.colors.count])
                            .frame(width: 7, height: i % 2 == 0 ? 7 : 12)
                            .rotationEffect(.radians(a + Double(p) * 3))
                            .offset(x: cos(a) * r, y: sin(a) * r + p * p * 40)
                            .opacity(p >= 1 ? 0 : Double(1 - p))
                    }
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 58)).foregroundStyle(Theme.green)
                        .scaleEffect(p >= 1 ? 0.4 : 0.8 + 0.5 * min(1, p * 4))
                        .opacity(p >= 1 ? 0 : p < 0.7 ? 1 : Double((1 - p) / 0.3))
                }
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(CGFloat(0), duration: 0.01)
                    CubicKeyframe(CGFloat(1), duration: 1.4)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: Ticker

struct StudioTicker: View {
    let d: StudioDirector
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg").font(.system(size: 12)).foregroundStyle(Theme.textFaint)
            HStack(spacing: 6) {
                ForEach(d.ticker.reversed(), id: \.stableId) { e in
                    HStack(spacing: 5) {
                        Image(systemName: e.icon).font(.system(size: 10.5))
                            .foregroundStyle(e.tint == "other" ? Theme.textDim : Theme.status(e.tint))
                        Text(stepTitle(e)).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textDim)
                    .padding(.horizontal, 9).frame(height: 24)
                    .background(Theme.raised, in: Capsule())
                    .frame(maxWidth: 230)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity), removal: .opacity))
                }
            }
            Spacer(minLength: 0)
            if d.queued > 0 {
                Text("+\(d.queued) coming").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.purple)
                    .contentTransition(.numericText(value: Double(d.queued)))
            }
        }
        .padding(.horizontal, 14).frame(height: 38)
        .background(Theme.surface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        .clipped()
    }
}

// MARK: - Shared bits

/// Round agent avatar; a spinning ring while it works, amber ring when it needs you.
struct AgentAvatar: View {
    let kind: String
    let status: String
    var size: CGFloat = 28
    @State private var spin = false

    var tint: Color { kind == "claude" ? Theme.accent : Theme.blue }

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.16))
            Image(systemName: kind == "claude" ? "sparkle" : "terminal")
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(tint)
                .symbolEffect(.pulse, isActive: status == "working")
        }
        .frame(width: size, height: size)
        .overlay {
            if status == "working" {
                Circle()
                    .stroke(AngularGradient(colors: [tint, tint.opacity(0.0), tint.opacity(0.0), tint], center: .center), style: StrokeStyle(lineWidth: max(1.5, size / 16), lineCap: .round))
                    .padding(-2.5)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .onAppear { withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { spin = true } }
            } else if status == "approval" {
                Circle().stroke(Theme.yellow, lineWidth: max(1.5, size / 16)).padding(-2.5)
            }
        }
        .accessibilityHidden(true)
    }
}

struct TypingDots: View {
    var color: Color = Theme.textDim
    var size: CGFloat = 4
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: size * 0.7) {
                ForEach(0..<3, id: \.self) { i in
                    let v = max(0, sin(t * 5.5 - Double(i) * 0.9))
                    Circle().fill(color).frame(width: size, height: size)
                        .opacity(0.35 + 0.65 * v)
                        .offset(y: -size * 0.5 * v)
                }
            }
        }
        .accessibilityHidden(true)
    }
}
