import SwiftUI
import UIKit

// Unified, chronological conversation feed for an AI coding agent.
// Every real event — messages, inline images/renders/contact sheets,
// syntax-highlighted expandable diffs, file operations, terminal commands
// with live/expandable output, Python visualisations, embedded live desktop
// previews, builds, tests, errors and approvals — renders in one place.

// MARK: - Full-screen inspection model

struct InspectionImage: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String?
    let apiPath: String
    let query: [String: String?]
}

enum InspectionItem: Identifiable {
    case images([InspectionImage], initial: Int)
    case code(title: String, path: String, text: String, isDiff: Bool, project: String?, relPath: String?)
    case filePath(title: String, absPath: String)
    case visual(project: String, item: VisualItem)

    var id: String {
        switch self {
        case .images(let imgs, let idx): return "img-\(imgs.first?.id ?? "")-\(idx)"
        case .code(let t, let p, _, let d, _, _): return "code-\(t)-\(p)-\(d)"
        case .filePath(_, let p): return "file-\(p)"
        case .visual(let p, let it): return "vis-\(p)-\(it.path)-\(it.mtime)"
        }
    }
}

// MARK: - Feed grouping

enum FeedEntry: Identifiable {
    case single(TimelineEvent)
    case steps([TimelineEvent])
    case edits([TimelineEvent])
    case images([TimelineEvent])

    var id: String {
        switch self {
        case .single(let e): return e.stableId
        case .steps(let es): return "steps-" + (es.first?.stableId ?? "")
        case .edits(let es): return "edits-" + (es.first?.stableId ?? "")
        case .images(let es): return "images-" + (es.first?.stableId ?? "")
        }
    }
    var lastEvent: TimelineEvent? {
        switch self {
        case .single(let e): return e
        case .steps(let es), .edits(let es), .images(let es): return es.last
        }
    }
}

enum Feed {
    static func isTestResult(_ e: TimelineEvent) -> Bool {
        if e.kind == "agent.test" { return e.detail?["exitCode"]?.number != nil || !(e.detail?["output"]?.string ?? "").isEmpty }
        return (e.kind == "agent.command_done" || e.kind == "agent.command_failed") && e.detail?["test"]?.bool == true
    }

    static func isDesktop(_ e: TimelineEvent) -> Bool {
        e.follow?["view"]?.string == "vnc"
    }

    static func isImage(_ e: TimelineEvent) -> Bool {
        e.kind == "agent.image" || e.kind == "screenshot.new"
    }

    static func isBuild(_ e: TimelineEvent) -> Bool {
        e.kind == "build.started" || e.kind == "build.finished" || e.kind == "build.cancelled"
    }

    static func isRoutine(_ e: TimelineEvent) -> Bool {
        if isTestResult(e) || isDesktop(e) || isImage(e) || isBuild(e) { return false }
        switch e.kind {
        case "agent.command", "agent.command_done", "agent.tool", "agent.read", "agent.test", "agent.started", "agent.approval_cleared":
            return true
        default:
            return false
        }
    }

    static func build(_ events: [TimelineEvent]) -> [FeedEntry] {
        // Deduplicate the app's own "You:" instruction against the transcript's copy.
        let prompts = events.filter { $0.kind == "agent.prompt" }
        let filtered = events.filter { e in
            guard e.kind == "agent.instruction" else { return true }
            let t = String((e.detail?["text"]?.string ?? e.title).prefix(40))
            return !prompts.contains {
                abs($0.ts - e.ts) < 120_000 &&
                ($0.detail?["text"]?.string ?? $0.title).hasPrefix(t.replacingOccurrences(of: "You: ", with: ""))
            }
        }
        var out: [FeedEntry] = []
        var steps: [TimelineEvent] = []
        var edits: [TimelineEvent] = []
        var images: [TimelineEvent] = []

        func flushSteps() {
            guard !steps.isEmpty else { return }
            out.append(steps.count == 1 && steps[0].kind != "agent.read" ? .single(steps[0]) : .steps(steps))
            steps = []
        }
        func flushEdits() {
            guard !edits.isEmpty else { return }
            out.append(.edits(edits))
            edits = []
        }
        func flushImages() {
            guard !images.isEmpty else { return }
            out.append(images.count == 1 ? .single(images[0]) : .images(images))
            images = []
        }
        func flushAll() { flushSteps(); flushEdits(); flushImages() }

        for e in filtered {
            if e.kind == "agent.edit" || e.kind == "file.changed" {
                flushSteps(); flushImages()
                edits.append(e)
                continue
            }
            if isImage(e) {
                flushSteps(); flushEdits()
                images.append(e)
                continue
            }
            if isRoutine(e) {
                flushEdits(); flushImages()
                steps.append(e)
                continue
            }
            flushAll()
            out.append(.single(e))
        }
        flushAll()
        return out
    }

    /// Pass/fail counts quoted from real runner output.
    static func testSummary(_ output: String) -> String? {
        let lines = output.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
        let patterns = [#"^#\s*(pass|fail|tests)\s+\d+"#, #"^Tests?:?\s+.*\d+\s+(passed|failed)"#, #"\d+\s+(passed|failed|passing|failing)\b"#, #"^(OK|FAILED)\s*\("#, #"Executed \d+ tests?"#]
        var found: [String] = []
        for l in lines.reversed() where found.count < 3 {
            if patterns.contains(where: { l.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }) {
                found.insert(String(l.prefix(120)), at: 0)
            }
        }
        return found.isEmpty ? nil : found.joined(separator: " · ")
    }
}

// MARK: - Unified feed entry dispatcher

struct FeedEntryView: View {
    let entry: FeedEntry
    let agent: Agent
    let latestMessageId: String?
    let latestDesktopId: String?
    let runningCommandId: String?
    let inspect: (InspectionItem) -> Void

    var body: some View {
        switch entry {
        case .steps(let es):
            StepsGroup(events: es, agent: agent, runningCommandId: runningCommandId, inspect: inspect)
        case .edits(let es):
            EditsGroup(events: es, inspect: inspect)
        case .images(let es):
            InlineImageGallery(events: es, inspect: inspect)
        case .single(let e):
            single(e)
        }
    }

    @ViewBuilder func single(_ e: TimelineEvent) -> some View {
        if Feed.isDesktop(e) {
            InlineDesktopCard(event: e, agent: agent, isLivePreview: e.stableId == latestDesktopId && agent.isLive)
        } else if e.kind == "visual.output" {
            VisualArtifactCard(event: e, agentProject: agent.project, inspect: inspect)
        } else if Feed.isBuild(e) {
            BuildCard(event: e, inspect: inspect)
        } else if Feed.isImage(e) {
            InlineImageCard(event: e, inspect: inspect)
        } else {
            switch e.kind {
            case "agent.prompt", "agent.instruction":
                PromptBubble(event: e)
            case "agent.message":
                MessageBlock(event: e, prominent: e.stableId == latestMessageId, inspect: inspect)
            case "agent.approval":
                ApprovalNote(event: e)
            case "agent.approval_answered":
                AnsweredNote(event: e)
            case "agent.done", "agent.stopped", "agent.ended":
                TurnDivider(event: e)
            case "agent.error":
                ErrorCard(event: e, inspect: inspect)
            case "agent.plan":
                PlanCard(event: e)
            case "agent.command_failed" where !Feed.isTestResult(e):
                FailureCard(event: e, inspect: inspect)
            default:
                if Feed.isTestResult(e) {
                    TestCard(event: e, inspect: inspect)
                } else if e.stableId == runningCommandId && agent.isLive {
                    LiveCommandCard(event: e, agent: agent, inspect: inspect)
                } else {
                    StepRow(event: e, inspect: inspect)
                }
            }
        }
    }
}

// MARK: - Conversation messages

struct PromptBubble: View {
    let event: TimelineEvent
    @State private var expanded = false
    var text: String {
        (event.detail?["text"]?.string ?? event.title).replacingOccurrences(of: "You: ", with: "", options: .anchored)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.fill").font(.system(size: 13)).foregroundStyle(Theme.accent)
                Text("You").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.accent)
                Text(Fmt.time(event.ts)).font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
                Spacer()
            }
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(Theme.text)
                .lineSpacing(3)
                .lineLimit(expanded ? nil : 10)
                .textSelection(.enabled)
            if text.count > 700 || text.filter({ $0 == "\n" }).count > 9 {
                Button(expanded ? "Show less" : "Show full prompt") {
                    withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                }
                .font(Theme.caption).foregroundStyle(Theme.accent).buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .padding(.vertical, 8)
    }
}

struct MessageBlock: View {
    let event: TimelineEvent
    var prominent = false
    var inspect: ((InspectionItem) -> Void)? = nil
    @State private var expanded = false
    var text: String { event.detail?["text"]?.string ?? event.title }

    var body: some View {
        let segs = MessageText.segments(text)
        let long = text.count > 2200 && !prominent
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array((long && !expanded ? Array(segs.prefix(2)) : segs).enumerated()), id: \.offset) { _, seg in
                switch seg {
                case .prose(let p): ProseText(text: p, size: prominent ? 15.5 : 15)
                case .code(let lang, let code): CodeBlockView(code: code, language: lang, inspect: inspect)
                }
            }
            if long {
                Button(expanded ? "Show less" : "Show full reply") {
                    withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                }
                .font(Theme.caption).foregroundStyle(Theme.accent).buttonStyle(.plain)
            }
        }
        .padding(.vertical, prominent ? 12 : 8)
        .padding(.horizontal, prominent ? 14 : 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(prominent ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 14))
        .overlay { if prominent { RoundedRectangle(cornerRadius: 14).stroke(Theme.line) } }
        .padding(.vertical, prominent ? 6 : 2)
    }
}

enum MessageText {
    enum Segment { case prose(String), code(String, String) }
    static func segments(_ s: String) -> [Segment] {
        var out: [Segment] = []
        var prose: [String] = [], code: [String] = [], lang = "", inCode = false
        for line in s.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                if inCode { out.append(.code(lang, code.joined(separator: "\n"))); code = []; inCode = false }
                else {
                    if !prose.isEmpty { out.append(.prose(prose.joined(separator: "\n"))); prose = [] }
                    lang = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    inCode = true
                }
                continue
            }
            if inCode { code.append(line) } else { prose.append(line) }
        }
        if inCode { out.append(.code(lang, code.joined(separator: "\n"))) }
        if !prose.isEmpty { out.append(.prose(prose.joined(separator: "\n"))) }
        return out.filter {
            if case .prose(let p) = $0 { return !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return true
        }
    }
}

struct ProseText: View {
    let text: String
    var size: CGFloat = 15
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { Color.clear.frame(height: 2) }
                else if line.hasPrefix("#") {
                    Text(inline(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
                        .font(.system(size: size + 1.5, weight: .semibold))
                        .padding(.top, 4)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.range(of: #"^\d+[.)] "#, options: .regularExpression) != nil {
                    let isNum = line.first?.isNumber == true
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(isNum ? String(line.prefix(while: { $0 != " " })) : "•").font(.system(size: size)).foregroundStyle(Theme.textDim)
                        Text(inline(isNum ? String(line.drop(while: { $0 != " " }).dropFirst()) : String(line.dropFirst(2)))).font(.system(size: size))
                    }
                    .padding(.leading, raw.prefix(while: { $0 == " " }).count >= 2 ? 16 : 2)
                } else {
                    Text(inline(line)).font(.system(size: size))
                }
            }
        }
        .foregroundStyle(Theme.text).lineSpacing(3).textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// Fenced code: syntax-highlighted, copyable, and full-screen inspectable.
struct CodeBlockView: View {
    let code: String
    var language: String = ""
    var inspect: ((InspectionItem) -> Void)? = nil
    @State private var expanded = false
    @State private var copied = false

    var lines: [String] { code.components(separatedBy: "\n") }
    var ext: String {
        let l = language.lowercased()
        let map = ["swift": "swift", "js": "js", "javascript": "js", "ts": "ts", "typescript": "ts", "tsx": "tsx",
                   "python": "py", "py": "py", "bash": "sh", "sh": "sh", "shell": "sh", "zsh": "sh",
                   "json": "json", "yaml": "yml", "yml": "yml", "gdscript": "gd", "html": "html", "css": "css", "kotlin": "kt", "diff": "diff"]
        return map[l] ?? "txt"
    }

    var body: some View {
        let isDiff = ext == "diff" || (lines.filter { $0.hasPrefix("+") || $0.hasPrefix("-") }.count > lines.count / 2 && lines.count > 3)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(language.isEmpty ? "code" : language).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.textFaint)
                Spacer()
                Text("\(lines.count) line\(lines.count == 1 ? "" : "s")").font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
                Button { UIPasteboard.general.string = code; copied = true } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 12)).frame(width: 28, height: 24)
                }
                .buttonStyle(.plain).foregroundStyle(Theme.textDim).accessibilityLabel(Text("Copy code"))
                if let inspect {
                    Button {
                        inspect(.code(title: language.isEmpty ? "Code" : language, path: "snippet.\(ext)", text: code, isDiff: isDiff, project: nil, relPath: nil))
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11.5)).frame(width: 28, height: 24)
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.textDim).accessibilityLabel(Text("Inspect code full screen"))
                }
            }
            .padding(.leading, 10).padding(.trailing, 4).frame(height: 30)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }

            if isDiff {
                DiffView(diff: code).frame(height: min(CGFloat(lines.count) * 19 + 16, expanded ? 720 : 280))
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.prefix(expanded ? 4000 : 24).enumerated()), id: \.offset) { _, l in
                            Text(SyntaxHighlighter.attributed(l, path: "snippet.\(ext)")).font(Theme.mono).fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    .padding(10).textSelection(.enabled)
                }
            }
            if lines.count > 24 {
                Button(expanded ? "Collapse" : "Show all \(lines.count) lines") {
                    withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                }
                .font(Theme.caption).foregroundStyle(Theme.accent).buttonStyle(.plain).padding(.horizontal, 10).padding(.bottom, 8)
            }
        }
        .background(Theme.raised.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
    }
}

// MARK: - Inline images, renders & contact sheets

/// Resolves an image event (screenshot.new or agent.image) to an authenticated
/// thumbnail + full-res gateway path.
private struct ResolvedImage: Hashable {
    let thumbPath: String
    let thumbQuery: [String: String?]
    let fullPath: String
    let fullQuery: [String: String?]
    let name: String
}

private func resolveImageSource(event: TimelineEvent, app: AppModel) async -> ResolvedImage? {
    let rawPath = event.detail?["path"]?.string
    let name = (rawPath as NSString?)?.lastPathComponent ?? event.title
    if let id = event.detail?["id"]?.number {
        let i = Int(id)
        return ResolvedImage(thumbPath: "/api/screenshots/\(i)/image", thumbQuery: ["w": "960"], fullPath: "/api/screenshots/\(i)/image", fullQuery: [:], name: name)
    }
    if let path = rawPath, let loc = app.locate(path) {
        return ResolvedImage(thumbPath: "/api/projects/\(loc.project.id)/thumb", thumbQuery: ["path": loc.rel, "w": "960"], fullPath: "/api/projects/\(loc.project.id)/raw", fullQuery: ["path": loc.rel], name: name)
    }
    if let path = rawPath {
        for _ in 0..<4 {
            if let list = try? await app.client.get("/api/screenshots", ["session": event.session, "limit": "100"], as: [Screenshot].self),
               let s = list.first(where: { $0.path == path || $0.path.hasSuffix("/" + name) }) {
                return ResolvedImage(thumbPath: "/api/screenshots/\(s.id)/image", thumbQuery: ["w": "960"], fullPath: "/api/screenshots/\(s.id)/image", fullQuery: [:], name: name)
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
    }
    return nil
}

/// Single inline image / render / screenshot at natural aspect ratio; tap for full-screen zoom.
struct InlineImageCard: View {
    let event: TimelineEvent
    let inspect: (InspectionItem) -> Void
    @Environment(AppModel.self) private var app
    @State private var resolved: ResolvedImage?
    @State private var missing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "photo").font(.system(size: 12)).foregroundStyle(Theme.purple).frame(width: 18)
                Text(resolved?.name ?? event.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textDim).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(Fmt.time(event.ts)).font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
            }
            Group {
                if let r = resolved {
                    Button {
                        let img = InspectionImage(id: event.stableId, title: r.name, subtitle: Fmt.time(event.ts), apiPath: r.fullPath, query: r.fullQuery)
                        inspect(.images([img], initial: 0))
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            AuthImage(path: r.thumbPath, query: r.thumbQuery, contentMode: .fit)
                                .frame(maxWidth: 540, maxHeight: 340, alignment: .leading)
                                .clipShape(RoundedRectangle(cornerRadius: 11))
                                .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.line))
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(6)
                                .background(.black.opacity(0.48), in: Circle())
                                .padding(8)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Inspect \(r.name) full screen"))
                } else if missing {
                    HStack(spacing: 6) {
                        Image(systemName: "photo.badge.exclamationmark").foregroundStyle(Theme.textFaint)
                        Text((event.detail?["path"]?.string as NSString?)?.lastPathComponent ?? event.title).font(Theme.monoSmall).foregroundStyle(Theme.textFaint)
                    }
                    .padding(10)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 9))
                } else {
                    RoundedRectangle(cornerRadius: 11).fill(Theme.raised).frame(width: 260, height: 150)
                        .overlay(ProgressView().controlSize(.small))
                }
            }
            .padding(.leading, 26)
        }
        .padding(.vertical, 6)
        .task(id: event.stableId) {
            if let r = await resolveImageSource(event: event, app: app) { resolved = r } else { missing = true }
        }
    }
}

/// Consecutive images / renders / contact sheets displayed as a clean inline grid.
struct InlineImageGallery: View {
    let events: [TimelineEvent]
    let inspect: (InspectionItem) -> Void
    @Environment(AppModel.self) private var app
    @State private var resolved: [String: ResolvedImage] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "photo.on.rectangle.angled").font(.system(size: 12)).foregroundStyle(Theme.purple).frame(width: 18)
                Text("\(events.count) images").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textDim)
                Spacer()
                if let last = events.last { Text(Fmt.time(last.ts)).font(.system(size: 11.5)).foregroundStyle(Theme.textFaint) }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 260), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(Array(events.enumerated()), id: \.element.stableId) { idx, e in
                    if let r = resolved[e.stableId] {
                        Button {
                            let all = events.compactMap { ev -> InspectionImage? in
                                guard let res = resolved[ev.stableId] else { return nil }
                                return InspectionImage(id: ev.stableId, title: res.name, subtitle: Fmt.time(ev.ts), apiPath: res.fullPath, query: res.fullQuery)
                            }
                            let targetIdx = all.firstIndex { $0.id == e.stableId } ?? 0
                            if !all.isEmpty { inspect(.images(all, initial: targetIdx)) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                AuthImage(path: r.thumbPath, query: r.thumbQuery, contentMode: .fill)
                                    .frame(height: 132)
                                    .frame(maxWidth: .infinity)
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 9))
                                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
                                Text(r.name).font(.system(size: 11.5)).foregroundStyle(Theme.textDim).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Inspect \(r.name) full screen"))
                    } else {
                        RoundedRectangle(cornerRadius: 9).fill(Theme.raised).frame(height: 132)
                            .overlay(ProgressView().controlSize(.small))
                    }
                }
            }
            .padding(.leading, 26)
        }
        .padding(.vertical, 6)
        .task(id: events.map(\.stableId).joined(separator: ",")) {
            for e in events where resolved[e.stableId] == nil {
                if let r = await resolveImageSource(event: e, app: app) {
                    resolved[e.stableId] = r
                }
            }
        }
    }
}

// MARK: - Live & grouped commands / routine steps

func stepTitle(_ e: TimelineEvent) -> String {
    var t = e.title
    for p in ["$ ", "Finished: ", "Running tests: "] where t.hasPrefix(p) { t = String(t.dropFirst(p.count)) }
    return t
}

/// Currently running terminal command with real-time streaming output from tmux.
struct LiveCommandCard: View {
    let event: TimelineEvent
    let agent: Agent
    let inspect: (InspectionItem) -> Void
    @Environment(AppModel.self) private var app
    @State private var screenText: String = ""
    @State private var expanded = false

    var command: String { event.detail?["command"]?.string ?? stepTitle(event) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini).frame(width: 18)
                Text("$ " + command).font(Theme.monoSmall).foregroundStyle(Theme.text).lineLimit(2).truncationMode(.tail)
                Spacer(minLength: 6)
                Pill(text: "running", color: Theme.blue)
            }
            if !screenText.isEmpty {
                let tailLines = screenText.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                let preview = tailLines.suffix(expanded ? 80 : 6).joined(separator: "\n")
                LogBox(text: preview, maxHeight: expanded ? 320 : 120)
                HStack(spacing: 12) {
                    Button(expanded ? "Collapse output" : "Expand live output") {
                        withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                    }
                    .font(Theme.caption).foregroundStyle(Theme.accent).buttonStyle(.plain)
                    Button("Full screen") {
                        inspect(.code(title: "$ " + command, path: "output.sh", text: screenText, isDiff: false, project: nil, relPath: nil))
                    }
                    .font(Theme.caption).foregroundStyle(Theme.textDim).buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.blue.opacity(0.3)))
        .padding(.vertical, 4)
        .task(id: event.stableId) {
            guard agent.controllable else { return }
            while !Task.isCancelled && agent.isLive {
                if let cap = try? await app.client.get("/api/agents/\(agent.id.pathSegment)/screen", ["ansi": "0", "lines": "120"], as: ScreenCapture.self),
                   let t = cap.text {
                    screenText = t
                }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
        }
    }
}

/// Single step row (command, file read, tool call) with inline expandable output or full-screen file inspection.
struct StepRow: View {
    let event: TimelineEvent
    let inspect: (InspectionItem) -> Void
    @State private var expanded = false

    var output: String? {
        let s = event.detail?["output"]?.string ?? event.detail?["input"]?.string
        return (s?.isEmpty == false) ? s : nil
    }
    var readPath: String? { event.kind == "agent.read" ? event.detail?["path"]?.string : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if let p = readPath {
                    inspect(.filePath(title: (p as NSString).lastPathComponent, absPath: p))
                } else if output != nil {
                    withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Image(systemName: event.icon)
                        .font(.system(size: 12))
                        .foregroundStyle(event.tint == "other" ? Theme.textFaint : Theme.status(event.tint))
                        .frame(width: 18)
                    Text(stepTitle(event))
                        .font(event.kind.contains("command") || event.kind == "agent.test" ? Theme.monoSmall : .system(size: 13))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(expanded ? nil : 2)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    if let code = event.detail?["exitCode"]?.number, Int(code) != 0 {
                        Pill(text: "exit \(Int(code))", color: Theme.red)
                    }
                    if readPath != nil {
                        Image(systemName: "doc.text.magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                    } else if output != nil {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textFaint)
                    }
                    Text(Fmt.time(event.ts)).font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
                }
                .padding(.vertical, 5).padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded, let output {
                VStack(alignment: .leading, spacing: 6) {
                    if let cmd = event.detail?["command"]?.string {
                        Text("$ " + cmd).font(Theme.monoSmall).foregroundStyle(Theme.accent).textSelection(.enabled)
                    }
                    LogBox(text: output, maxHeight: 240)
                    Button("Inspect full screen") {
                        inspect(.code(title: stepTitle(event), path: "output.txt", text: output, isDiff: false, project: nil, relPath: nil))
                    }
                    .font(Theme.caption).foregroundStyle(Theme.accent).buttonStyle(.plain)
                }
                .padding(.leading, 27).padding(.bottom, 6)
            }
        }
    }
}

struct StepsGroup: View {
    let events: [TimelineEvent]
    let agent: Agent
    let runningCommandId: String?
    let inspect: (InspectionItem) -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 9) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textFaint)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 18)
                    Text(summary).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textDim)
                    if !expanded, let last = events.last {
                        Text(stepTitle(last)).font(Theme.monoSmall).foregroundStyle(Theme.textFaint).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 6)
                    if let l = events.last { Text(Fmt.time(l.ts)).font(.system(size: 11.5)).foregroundStyle(Theme.textFaint) }
                }
                .padding(.vertical, 6).padding(.horizontal, 6).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("\(summary). \(expanded ? "Collapse" : "Expand")"))

            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(events, id: \.stableId) { e in
                        if e.stableId == runningCommandId && agent.isLive {
                            LiveCommandCard(event: e, agent: agent, inspect: inspect)
                        } else {
                            StepRow(event: e, inspect: inspect)
                        }
                    }
                }
                .padding(.leading, 14)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.line).frame(width: 1).padding(.leading, 14) }
            }
        }
    }

    var summary: String {
        let commands = events.filter { $0.kind.hasPrefix("agent.command") || $0.kind == "agent.test" }.count
        let reads = events.filter { $0.kind == "agent.read" }.count
        let tools = events.filter { $0.kind == "agent.tool" }.count
        var parts: [String] = []
        if commands > 0 { parts.append("\(commands) command\(commands == 1 ? "" : "s")") }
        if reads > 0 { parts.append("read \(reads) file\(reads == 1 ? "" : "s")") }
        if tools > 0 { parts.append("\(tools) tool call\(tools == 1 ? "" : "s")") }
        let other = events.count - commands - reads - tools
        if other > 0 { parts.append("\(other) other step\(other == 1 ? "" : "s")") }
        return parts.joined(separator: ", ").capitalizingFirst
    }
}

extension String { var capitalizingFirst: String { prefix(1).uppercased() + dropFirst() } }

// MARK: - Inline expandable code changes & diffs

struct EditsGroup: View {
    let events: [TimelineEvent]
    let inspect: (InspectionItem) -> Void
    @State private var expandedFileId: String?

    struct EditedFile: Identifiable {
        let id: String
        let path: String
        let name: String
        let badge: String
        let badgeColor: Color
        let event: TimelineEvent
        let added: Int
        let removed: Int
        let inlineDiff: String?
    }

    var files: [EditedFile] {
        var seen = Set<String>()
        var out: [EditedFile] = []
        for e in events.reversed() {
            let p = e.detail?["path"]?.string ?? e.title
            guard seen.insert(p).inserted else { continue }
            var a = 0, r = 0
            var diffText: String? = nil
            if let d = e.detail?["diff"]?.string, !d.isEmpty {
                diffText = d
                for l in d.split(separator: "\n") {
                    if l.hasPrefix("+") && !l.hasPrefix("+++") { a += 1 }
                    else if l.hasPrefix("-") && !l.hasPrefix("---") { r += 1 }
                }
            } else if let edits = e.detail?["edits"]?.array, !edits.isEmpty {
                let name = (p as NSString).lastPathComponent
                diffText = edits.map {
                    DiffParser.fromEdit(old: $0["old"]?.string ?? "", new: $0["new"]?.string ?? "", path: name)
                }.joined(separator: "\n")
                for x in edits {
                    a += (x["new"]?.string ?? "").split(separator: "\n", omittingEmptySubsequences: false).count
                    r += (x["old"]?.string ?? "").split(separator: "\n", omittingEmptySubsequences: false).count
                }
            }
            let change = e.detail?["change"]?.string
            let tool = e.detail?["tool"]?.string
            let (badge, color): (String, Color) = {
                if change == "add" { return ("Created", Theme.green) }
                if change == "delete" { return ("Deleted", Theme.red) }
                if tool == "Write" || change == "write" { return ("Wrote", Theme.green) }
                return ("Edited", Theme.blue)
            }()
            out.append(EditedFile(id: e.stableId, path: p, name: (p as NSString).lastPathComponent, badge: badge, badgeColor: color, event: e, added: a, removed: r, inlineDiff: diffText))
        }
        return out.reversed()
    }

    var body: some View {
        let fs = files
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Image(systemName: "pencil.line").font(.system(size: 12)).foregroundStyle(Theme.blue).frame(width: 18)
                Text(fs.count == 1 ? "\(fs[0].badge) \(fs[0].name)" : "Changed \(fs.count) files")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textDim)
                Spacer()
                if let l = events.last { Text(Fmt.time(l.ts)).font(.system(size: 11.5)).foregroundStyle(Theme.textFaint) }
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(fs) { f in
                    InlineEditCard(file: f, isExpanded: expandedFileId == f.id, toggle: {
                        withAnimation(.easeOut(duration: 0.15)) {
                            expandedFileId = expandedFileId == f.id ? nil : f.id
                        }
                    }, inspect: inspect)
                }
            }
            .padding(.leading, 26)
        }
        .padding(.vertical, 6)
    }
}

struct InlineEditCard: View {
    let file: EditsGroup.EditedFile
    let isExpanded: Bool
    let toggle: () -> Void
    let inspect: (InspectionItem) -> Void
    @Environment(AppModel.self) private var app
    @State private var fetchedDiff: String?
    @State private var fetchedText: String?
    @State private var loading = false

    var effectiveDiff: String? { file.inlineDiff ?? fetchedDiff }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button(action: toggle) {
                    HStack(spacing: 6) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Theme.textFaint)
                        Pill(text: file.badge, color: file.badgeColor)
                        Text(app.locate(file.path)?.rel ?? file.name)
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1).truncationMode(.head)
                        Spacer(minLength: 4)
                        if file.added > 0 { Text("+\(file.added)").font(.system(size: 11.5, weight: .medium, design: .monospaced)).foregroundStyle(Theme.green) }
                        if file.removed > 0 { Text("−\(file.removed)").font(.system(size: 11.5, weight: .medium, design: .monospaced)).foregroundStyle(Theme.red) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if let loc = app.locate(file.path) {
                    Button { app.openFile(project: loc.project.id, path: loc.rel) } label: {
                        Image(systemName: "arrow.up.forward.square").font(.system(size: 12.5)).foregroundStyle(Theme.textDim)
                    }
                    .buttonStyle(.plain).help("Open in Files")
                }
                Button { openFullScreen() } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11.5)).foregroundStyle(Theme.textDim)
                }
                .buttonStyle(.plain).help("Inspect full screen")
            }
            .padding(.horizontal, 10).frame(height: 34)

            if isExpanded {
                Rectangle().fill(Theme.line).frame(height: 1)
                Group {
                    if let d = effectiveDiff, !d.isEmpty {
                        DiffView(diff: d).frame(height: min(max(120, CGFloat(d.split(separator: "\n").count) * 19 + 34), 340))
                    } else if let t = fetchedText {
                        CodeView(text: t, path: file.path).frame(height: 260)
                    } else if loading {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(16)
                    } else {
                        Text("No diff recorded for this change.").font(Theme.caption).foregroundStyle(Theme.textFaint).padding(10)
                    }
                }
                .task(id: file.id) { await loadIfNeeded() }
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
    }

    func openFullScreen() {
        let loc = app.locate(file.path)
        if let d = effectiveDiff, !d.isEmpty {
            inspect(.code(title: file.name, path: file.path, text: d, isDiff: true, project: loc?.project.id, relPath: loc?.rel))
        } else if let t = fetchedText {
            inspect(.code(title: file.name, path: file.path, text: t, isDiff: false, project: loc?.project.id, relPath: loc?.rel))
        } else {
            inspect(.filePath(title: file.name, absPath: file.path))
        }
    }

    func loadIfNeeded() async {
        guard effectiveDiff == nil && fetchedText == nil else { return }
        loading = true
        defer { loading = false }
        if file.event.kind == "file.changed", let rev = file.event.detail?["revision"]?.number,
           let d = try? await app.client.get("/api/revisions/\(Int(rev))/diff", as: RevisionDiff.self), let diff = d.diff, !diff.isEmpty {
            fetchedDiff = diff; return
        }
        guard let loc = app.locate(file.path) else { return }
        if let revs = try? await app.client.get("/api/projects/\(loc.project.id)/revisions", ["path": loc.rel], as: [Revision].self), let r = revs.first,
           let d = try? await app.client.get("/api/revisions/\(r.id)/diff", as: RevisionDiff.self), let diff = d.diff, !diff.isEmpty {
            fetchedDiff = diff; return
        }
        if let f = try? await app.client.get("/api/projects/\(loc.project.id)/file", ["path": loc.rel], as: FileContent.self) {
            fetchedText = f.text
        }
    }
}

// MARK: - Python visualisations, graphs & generated artifacts

struct VisualArtifactCard: View {
    let event: TimelineEvent
    let agentProject: String?
    let inspect: (InspectionItem) -> Void

    var project: String { event.project ?? agentProject ?? "_shared" }
    var item: VisualItem { VisualItem(event: event) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: item.icon).font(.system(size: 12)).foregroundStyle(Theme.accent).frame(width: 18)
                Text(item.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                Pill(text: kindLabel, color: Theme.accent)
                Spacer()
                Button { inspect(.visual(project: project, item: item)) } label: {
                    Label("Inspect", systemImage: "arrow.up.left.and.arrow.down.right").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                Text(Fmt.time(event.ts)).font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
            }
            Group {
                if item.kind == "image" {
                    Button {
                        let img = InspectionImage(id: event.stableId, title: item.name, subtitle: Fmt.time(event.ts),
                                                  apiPath: "/api/visuals/\(project.pathSegment)/file", query: ["path": item.path])
                        inspect(.images([img], initial: 0))
                    } label: {
                        AuthImage(path: "/api/visuals/\(project.pathSegment)/file", query: ["path": item.path], contentMode: .fit)
                            .frame(maxWidth: 540, maxHeight: 340, alignment: .leading)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
                    }
                    .buttonStyle(.plain)
                } else {
                    VisualItemView(project: project, item: item)
                        .frame(height: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
                }
            }
            .padding(.leading, 26)
        }
        .padding(.vertical, 6)
    }

    var kindLabel: String {
        switch item.kind {
        case "image", "svg": return "Visual"
        case "html": return "Interactive"
        case "model": return "3D Model"
        case "video": return "Video"
        case "pdf": return "PDF"
        default: return "Artifact"
        }
    }
}

// MARK: - Embedded live desktop preview (Blender, browsers, GUI apps)

struct InlineDesktopCard: View {
    let event: TimelineEvent
    let agent: Agent
    let isLivePreview: Bool
    @Environment(AppModel.self) private var app
    @Environment(DesktopStore.self) private var desk

    var appLabel: String {
        if let g = event.detail?["guiApp"]?.string { return g.capitalizingFirst }
        if let f = event.follow?["app"]?.string { return f.capitalizingFirst }
        return "Desktop"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "display").font(.system(size: 12)).foregroundStyle(Theme.accent).frame(width: 18)
                Text("\(agent.shortName) · \(appLabel)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                if isLivePreview && desk.connected {
                    Pill(text: "Live :\(desk.display)", color: Theme.green)
                }
                Spacer()
                Button { app.showDesktop(follow: false) } label: {
                    Label("Full screen", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                Text(Fmt.time(event.ts)).font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
            }

            Text(stepTitle(event)).font(Theme.monoSmall).foregroundStyle(Theme.textDim).lineLimit(2).padding(.leading, 26)

            if isLivePreview && !app.showFullScreenDesktop && !app.fixtures {
                ZStack(alignment: .bottomTrailing) {
                    DesktopHost(store: desk)
                        .allowsHitTesting(false)
                        .frame(maxWidth: 540)
                        .aspectRatio(16.0 / 10.0, contentMode: .fit)
                        .background(Color(Theme.terminalBg))
                        .clipShape(RoundedRectangle(cornerRadius: 11))
                        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.lineStrong))
                    if !desk.connected {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini).tint(.white)
                            Text(desk.status).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.85))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(10)
                    } else {
                        Label("Tap to inspect & control", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.black.opacity(0.55), in: Capsule())
                            .padding(10)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { app.showDesktop(follow: false) }
                .padding(.leading, 26)
                .onAppear {
                    if !desk.active {
                        desk.open(client: app.client, machine: app.activeMachine?.id, presentation: .full)
                    }
                }
            } else {
                Button { app.showDesktop(follow: false) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.display").foregroundStyle(Theme.accent)
                        Text("Open live desktop preview").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                    }
                    .padding(.horizontal, 12).frame(height: 38)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
                }
                .buttonStyle(.plain)
                .padding(.leading, 26)
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Build progress, tests, failures, errors, approvals, plans

struct BuildCard: View {
    let event: TimelineEvent
    let inspect: (InspectionItem) -> Void
    @Environment(AppModel.self) private var app
    @State private var showLog = false
    @State private var logText: String?

    var buildId: String? { event.detail?["build"]?.string }
    var isRunning: Bool { event.kind == "build.started" }
    var isCancelled: Bool { event.kind == "build.cancelled" }
    var exitCode: Int? { event.detail?["exitCode"]?.number.map { Int($0) } }
    var succeeded: Bool { event.kind == "build.finished" && (exitCode ?? 0) == 0 }

    var tint: Color {
        if isRunning { return Theme.blue }
        if isCancelled { return Theme.textDim }
        return succeeded ? Theme.green : Theme.red
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if isRunning { ProgressView().controlSize(.small) }
                else { Image(systemName: succeeded ? "hammer.fill" : "exclamationmark.triangle.fill").foregroundStyle(tint) }
                Text(event.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(2)
                Spacer()
                if let code = exitCode, code != 0 { Pill(text: "exit \(code)", color: Theme.red) }
                Text(Fmt.time(event.ts)).font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
            }
            if let buildId {
                HStack(spacing: 12) {
                    Button(showLog ? "Hide log" : "Show build log") {
                        withAnimation(.easeOut(duration: 0.15)) { showLog.toggle() }
                    }
                    .font(Theme.caption).foregroundStyle(Theme.accent).buttonStyle(.plain)
                    if let logText, !logText.isEmpty {
                        Button("Full screen") {
                            inspect(.code(title: event.title, path: "build.log", text: logText, isDiff: false, project: nil, relPath: nil))
                        }
                        .font(Theme.caption).foregroundStyle(Theme.textDim).buttonStyle(.plain)
                    }
                    if isRunning {
                        Button("Cancel", role: .destructive) {
                            Task { _ = try? await app.client.send("POST", "/api/builds/\(buildId)/cancel", [:], as: OK.self) }
                        }
                        .font(Theme.caption).buttonStyle(.plain).foregroundStyle(Theme.red)
                    }
                }
                if showLog {
                    if let logText {
                        LogBox(text: logText, maxHeight: 260)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
        .padding(12)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.25)))
        .padding(.vertical, 4)
        .task(id: showLog) {
            guard showLog, let buildId else { return }
            if let l = try? await app.client.get("/api/builds/\(buildId)", as: BuildLog.self) { logText = l.text }
        }
    }
}

struct TestCard: View {
    let event: TimelineEvent
    let inspect: (InspectionItem) -> Void
    @State private var showLog = false

    var code: Int? { event.detail?["exitCode"]?.number.map { Int($0) } }
    var passed: Bool {
        if let code { return code == 0 }
        if event.kind == "agent.command_failed" { return false }
        return event.detail?["ok"]?.bool ?? true
    }
    var output: String { event.detail?["output"]?.string ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: passed ? "checkmark.seal.fill" : "xmark.seal.fill").font(.system(size: 16)).foregroundStyle(passed ? Theme.green : Theme.red)
                Text(passed ? "Tests passed" : "Tests failed").font(.system(size: 14.5, weight: .semibold)).foregroundStyle(passed ? Theme.green : Theme.red)
                if let code, code != 0 { Pill(text: "exit \(code)", color: Theme.red) }
                Spacer()
                Text(Fmt.time(event.ts)).font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
            }
            if let s = Feed.testSummary(output) { Text(s).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.text) }
            Text(event.detail?["command"]?.string ?? stepTitle(event)).font(Theme.monoSmall).foregroundStyle(Theme.textDim).lineLimit(2).truncationMode(.middle)
            if !output.isEmpty {
                HStack(spacing: 12) {
                    Button(showLog ? "Hide log" : "Show log") { withAnimation(.easeOut(duration: 0.15)) { showLog.toggle() } }
                        .font(Theme.caption).foregroundStyle(Theme.accent).buttonStyle(.plain)
                    Button("Full screen") {
                        inspect(.code(title: passed ? "Test output" : "Failed tests", path: "test.log", text: output, isDiff: false, project: nil, relPath: nil))
                    }
                    .font(Theme.caption).foregroundStyle(Theme.textDim).buttonStyle(.plain)
                }
                if showLog { LogBox(text: output, maxHeight: 280) }
            }
        }
        .padding(12)
        .background((passed ? Theme.green : Theme.red).opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke((passed ? Theme.green : Theme.red).opacity(0.25)))
        .padding(.vertical, 5)
    }
}

struct FailureCard: View {
    let event: TimelineEvent
    let inspect: (InspectionItem) -> Void
    @State private var showLog = false
    var output: String { event.detail?["output"]?.string ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Theme.red).frame(width: 18)
                Text(event.detail?["command"]?.string ?? stepTitle(event)).font(Theme.monoSmall).foregroundStyle(Theme.text).lineLimit(2).truncationMode(.middle)
                Spacer(minLength: 6)
                if let c = event.detail?["exitCode"]?.number { Pill(text: "exit \(Int(c))", color: Theme.red) } else { Pill(text: "failed", color: Theme.red) }
            }
            if !output.isEmpty {
                let tail = output.split(separator: "\n").suffix(showLog ? 400 : 3).joined(separator: "\n")
                if showLog { LogBox(text: tail, maxHeight: 260).padding(.leading, 27) }
                else { Text(tail).font(Theme.monoSmall).foregroundStyle(Theme.textDim).lineLimit(3).padding(.leading, 27) }
                HStack(spacing: 12) {
                    Button(showLog ? "Less" : "Full output") { withAnimation(.easeOut(duration: 0.15)) { showLog.toggle() } }
                        .font(Theme.caption).foregroundStyle(Theme.accent).buttonStyle(.plain)
                    Button("Full screen") {
                        inspect(.code(title: stepTitle(event), path: "error.log", text: output, isDiff: false, project: nil, relPath: nil))
                    }
                    .font(Theme.caption).foregroundStyle(Theme.textDim).buttonStyle(.plain)
                }
                .padding(.leading, 27)
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 8)
        .background(Theme.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .padding(.vertical, 3)
    }
}

struct LogBox: View {
    let text: String
    var maxHeight: CGFloat = 240
    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text).font(Theme.monoSmall).foregroundStyle(Theme.textDim).fixedSize(horizontal: true, vertical: false).textSelection(.enabled).padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: maxHeight)
        .background(Theme.raised.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ErrorCard: View {
    let event: TimelineEvent
    var inspect: ((InspectionItem) -> Void)? = nil
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.red)
            VStack(alignment: .leading, spacing: 4) {
                Text("Error").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.red)
                Text(event.detail?["message"]?.string ?? event.detail?["text"]?.string ?? event.title).font(.system(size: 13.5)).foregroundStyle(Theme.text).lineLimit(6).textSelection(.enabled)
                if let out = event.detail?["output"]?.string, !out.isEmpty {
                    LogBox(text: out, maxHeight: 160)
                    if let inspect {
                        Button("Full screen") {
                            inspect(.code(title: "Error output", path: "error.log", text: out, isDiff: false, project: nil, relPath: nil))
                        }
                        .font(Theme.caption).foregroundStyle(Theme.accent).buttonStyle(.plain)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12).background(Theme.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .padding(.vertical, 5)
    }
}

struct ApprovalNote: View {
    let event: TimelineEvent
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: "hand.raised.fill").font(.system(size: 12)).foregroundStyle(Theme.yellow).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.detail?["question"]?.string ?? event.title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.text).lineLimit(3)
                if let c = event.detail?["command"]?.string { Text(c).font(Theme.monoSmall).foregroundStyle(Theme.textDim).lineLimit(2) }
            }
            Spacer(minLength: 6)
            Text(Fmt.time(event.ts)).font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
        }
        .padding(.vertical, 7).padding(.horizontal, 8)
        .background(Theme.yellow.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        .padding(.vertical, 2)
    }
}

struct AnsweredNote: View {
    let event: TimelineEvent
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "checkmark.circle").font(.system(size: 12)).foregroundStyle(Theme.green).frame(width: 18)
            Text("Answered “\(event.detail?["option"]?.string ?? "?")”" + ((event.detail?["via"]?.string).map { " from \($0)" } ?? ""))
                .font(.system(size: 12.5)).foregroundStyle(Theme.textDim).lineLimit(1)
            Spacer()
            Text(Fmt.time(event.ts)).font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
        }
        .padding(.vertical, 3).padding(.horizontal, 6)
    }
}

struct TurnDivider: View {
    let event: TimelineEvent
    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Theme.line).frame(height: 1)
            Text(label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.textFaint).fixedSize()
            Rectangle().fill(Theme.line).frame(height: 1)
        }
        .padding(.vertical, 10)
    }
    var label: String {
        var t = event.kind == "agent.done" ? "Turn finished" : event.title
        if let ms = event.detail?["durationMs"]?.number, ms > 0 { t += " · " + Fmt.duration(ms / 1000) }
        return t + " · " + Fmt.time(event.ts)
    }
}

struct PlanCard: View {
    let event: TimelineEvent
    var body: some View {
        let items = event.detail?["items"]?.array ?? []
        let done = items.filter { $0["status"]?.string == "completed" }.count
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "checklist").foregroundStyle(Theme.blue)
                Text("Plan").font(.system(size: 13, weight: .semibold))
                Text("\(done) of \(items.count) done").font(Theme.caption).foregroundStyle(Theme.textDim)
                Spacer()
            }
            ForEach(Array(items.enumerated()), id: \.offset) { _, i in
                let st = i["status"]?.string
                Label {
                    Text(i["text"]?.string ?? "").strikethrough(st == "completed", color: Theme.textFaint).font(.system(size: 13.5)).foregroundStyle(st == "completed" ? Theme.textDim : Theme.text)
                } icon: {
                    Image(systemName: st == "completed" ? "checkmark.circle.fill" : st == "in_progress" ? "circle.dotted" : "circle")
                        .foregroundStyle(st == "completed" ? Theme.green : st == "in_progress" ? Theme.blue : Theme.textFaint)
                }
            }
        }
        .padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
        .padding(.vertical, 5)
    }
}

/// Live working status shown at the bottom of the conversation when the agent is actively working.
struct LiveProgressRow: View {
    let agent: Agent
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.lastEvent.map { stepTitleText($0.title) } ?? "Working…")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                Text("\(agent.agentName) is active")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textFaint)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
        .padding(.top, 6)
    }
    func stepTitleText(_ t: String) -> String { t.hasPrefix("$ ") ? "Running " + String(t.dropFirst(2)) : t }
}

// MARK: - Full-screen inspector

struct FullScreenInspector: View {
    let item: InspectionItem
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var index: Int = 0
    @State private var loadedText: String?
    @State private var loadError: String?
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(isDarkBackdrop ? Color(Theme.terminalBg) : Theme.bg)
        .onAppear {
            if case .images(_, let initial) = item { index = initial }
        }
    }

    var isDarkBackdrop: Bool {
        if case .images = item { return true }
        return false
    }

    var titleText: String {
        switch item {
        case .images(let imgs, _): return imgs.indices.contains(index) ? imgs[index].title : "Image"
        case .code(let t, _, _, _, _, _): return t
        case .filePath(let t, _): return t
        case .visual(_, let it): return it.name
        }
    }

    var topBar: some View {
        HStack(spacing: 10) {
            Text(titleText)
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(isDarkBackdrop ? .white : Theme.text)
                .lineLimit(1).truncationMode(.middle)
            if case .images(let imgs, _) = item, imgs.count > 1 {
                Text("\(index + 1) of \(imgs.count)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.65))
            }
            Spacer()
            if case .code(_, _, let text, _, let proj, let rel) = item {
                Button { UIPasteboard.general.string = text; copied = true } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").font(Theme.label)
                }
                .buttonStyle(.plain).foregroundStyle(Theme.textDim)
                if let proj, let rel {
                    Button("Open in Files") { app.openFile(project: proj, path: rel); dismiss() }
                        .font(Theme.label).foregroundStyle(Theme.accent)
                }
            }
            if case .filePath(_, let absPath) = item, let loc = app.locate(absPath) {
                Button("Open in Files") { app.openFile(project: loc.project.id, path: loc.rel); dismiss() }
                    .font(Theme.label).foregroundStyle(Theme.accent)
            }
            Button("Done") { dismiss() }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isDarkBackdrop ? .white : Theme.accent)
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .background(isDarkBackdrop ? Color.black.opacity(0.35) : Theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(isDarkBackdrop ? Color.white.opacity(0.12) : Theme.line).frame(height: 1) }
    }

    @ViewBuilder var content: some View {
        switch item {
        case .images(let imgs, _):
            TabView(selection: $index) {
                ForEach(Array(imgs.enumerated()), id: \.element.id) { i, img in
                    FullImage(path: img.apiPath, query: img.query).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: imgs.count > 1 ? .automatic : .never))
        case .code(_, let path, let text, let isDiff, _, _):
            if isDiff { DiffView(diff: text) }
            else { CodeView(text: text, path: path) }
        case .filePath(_, let absPath):
            Group {
                if let loadedText {
                    CodeView(text: loadedText, path: absPath)
                } else if let loadError {
                    EmptyNote(icon: "doc", text: "Can't open file", detail: loadError)
                } else {
                    ProgressView()
                }
            }
            .task(id: absPath) {
                guard let loc = app.locate(absPath) else { loadError = "This file is outside the configured projects."; return }
                do {
                    let f = try await app.client.get("/api/projects/\(loc.project.id)/file", ["path": loc.rel], as: FileContent.self)
                    loadedText = f.text ?? "(binary file)"
                } catch { loadError = error.localizedDescription }
            }
        case .visual(let proj, let it):
            VisualItemView(project: proj, item: it)
        }
    }
}

struct FullImage: View {
    let path: String
    let query: [String: String?]
    @Environment(AppModel.self) private var app
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { ZoomableImage(image: image) }
            else { ProgressView().tint(.white) }
        }
        .task(id: path) {
            image = await ImageCache.shared.image(client: app.client, path: path, query: query)
        }
    }
}
