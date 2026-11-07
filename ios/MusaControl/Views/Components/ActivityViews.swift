import SwiftUI
import UIKit

// Content-first rendering of an agent's activity. Each kind of event gets the
// presentation that suits it: conversation for prompts and replies, cards for
// test results, failures, approvals and images, and routine commands folded
// into one quiet "steps" row. Nothing here invents information: counts come
// from the events themselves, test summaries only from lines in the output.

/// One row of the feed: a single event, or a run of routine events folded together.
enum FeedEntry: Identifiable {
    case single(TimelineEvent)
    case steps([TimelineEvent])
    case edits([TimelineEvent])

    var id: String {
        switch self {
        case .single(let e): return e.stableId
        case .steps(let es): return "steps-" + (es.first?.stableId ?? "")
        case .edits(let es): return "edits-" + (es.first?.stableId ?? "")
        }
    }
    var lastEvent: TimelineEvent? {
        switch self { case .single(let e): return e; case .steps(let es), .edits(let es): return es.last }
    }
}

enum Feed {
    static func isTestResult(_ e: TimelineEvent) -> Bool {
        if e.kind == "agent.test" { return e.detail?["exitCode"]?.number != nil || !(e.detail?["output"]?.string ?? "").isEmpty }
        return (e.kind == "agent.command_done" || e.kind == "agent.command_failed") && e.detail?["test"]?.bool == true
    }
    static func isRoutine(_ e: TimelineEvent) -> Bool {
        if isTestResult(e) { return false }
        switch e.kind {
        case "agent.command", "agent.command_done", "agent.tool", "agent.read", "file.changed", "agent.test", "agent.started", "agent.approval_cleared": return true
        default: return false
        }
    }

    static func build(_ events: [TimelineEvent]) -> [FeedEntry] {
        // The app's own "You:" instruction and the agent's transcript copy of
        // the same prompt are one message.
        let prompts = events.filter { $0.kind == "agent.prompt" }
        let filtered = events.filter { e in
            guard e.kind == "agent.instruction" else { return true }
            let t = String((e.detail?["text"]?.string ?? e.title).prefix(40))
            return !prompts.contains { abs($0.ts - e.ts) < 120_000 && ($0.detail?["text"]?.string ?? $0.title).hasPrefix(t.replacingOccurrences(of: "You: ", with: "")) }
        }
        var out: [FeedEntry] = []
        var steps: [TimelineEvent] = [], edits: [TimelineEvent] = []
        func flush() {
            if !steps.isEmpty { out.append(steps.count == 1 && steps[0].kind != "agent.read" ? .single(steps[0]) : .steps(steps)); steps = [] }
            if !edits.isEmpty { out.append(.edits(edits)); edits = [] }
        }
        for e in filtered {
            if e.kind == "agent.edit" { if !steps.isEmpty { let s = steps; steps = []; out.append(.steps(s)) }; edits.append(e); continue }
            if isRoutine(e) { if !edits.isEmpty { out.append(.edits(edits)); edits = [] }; steps.append(e); continue }
            flush()
            out.append(.single(e))
        }
        flush()
        return out
    }

    /// Pass/fail counts quoted from the output, when the runner printed them.
    static func testSummary(_ output: String) -> String? {
        let lines = output.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
        let patterns = [#"^#\s*(pass|fail|tests)\s+\d+"#, #"^Tests?:?\s+.*\d+\s+(passed|failed)"#, #"\d+\s+(passed|failed|passing|failing)\b"#, #"^(OK|FAILED)\s*\("#, #"Executed \d+ tests?"#]
        var found: [String] = []
        for l in lines.reversed() where found.count < 3 {
            if patterns.contains(where: { l.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }) { found.insert(String(l.prefix(120)), at: 0) }
        }
        return found.isEmpty ? nil : found.joined(separator: " · ")
    }
}

// MARK: - Entry view

struct FeedEntryView: View {
    let entry: FeedEntry
    let latestMessageId: String?
    let select: (TimelineEvent) -> Void
    var selectedId: String?

    var body: some View {
        switch entry {
        case .steps(let es): StepsGroup(events: es, select: select, selectedId: selectedId)
        case .edits(let es): EditsGroup(events: es, select: select)
        case .single(let e): single(e)
        }
    }

    @ViewBuilder func single(_ e: TimelineEvent) -> some View {
        switch e.kind {
        case "agent.prompt", "agent.instruction": PromptBubble(event: e)
        case "agent.message": MessageBlock(event: e, prominent: e.stableId == latestMessageId)
        case "agent.image": ImageCard(event: e)
        case "agent.approval": ApprovalNote(event: e).onTapGesture { select(e) }
        case "agent.approval_answered": AnsweredNote(event: e)
        case "agent.done", "agent.stopped", "agent.ended": TurnDivider(event: e)
        case "agent.error": ErrorCard(event: e).onTapGesture { select(e) }
        case "agent.plan": PlanCard(event: e)
        case "agent.command_failed" where !Feed.isTestResult(e): FailureCard(event: e, select: select)
        default:
            if Feed.isTestResult(e) { TestCard(event: e, select: select) }
            else { StepRow(event: e, selected: selectedId == e.stableId).onTapGesture { select(e) } }
        }
    }
}

// MARK: - Conversation

struct PromptBubble: View {
    let event: TimelineEvent
    @State private var expanded = false
    var text: String { (event.detail?["text"]?.string ?? event.title).replacingOccurrences(of: "You: ", with: "", options: .anchored) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.fill").foregroundStyle(Theme.accent)
                Text("You").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.accent)
                Text(Fmt.time(event.ts)).font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
                Spacer()
            }
            Text(text).font(Theme.body).foregroundStyle(Theme.text).lineSpacing(2)
                .lineLimit(expanded ? nil : 10).textSelection(.enabled)
            if text.count > 700 || text.filter({ $0 == "\n" }).count > 9 {
                Button(expanded ? "Show less" : "Show full prompt") { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } }
                    .font(Theme.caption).foregroundStyle(Theme.accent).buttonStyle(.plain)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .padding(.vertical, 8)
    }
}

/// An agent reply: markdown prose, fenced code as scrollable code blocks.
struct MessageBlock: View {
    let event: TimelineEvent
    var prominent = false
    @State private var expanded = false
    var text: String { event.detail?["text"]?.string ?? event.title }

    var body: some View {
        let segs = MessageText.segments(text)
        let long = text.count > 1800 && !prominent
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array((long && !expanded ? Array(segs.prefix(2)) : segs).enumerated()), id: \.offset) { _, seg in
                switch seg {
                case .prose(let p): ProseText(text: p, size: prominent ? 15 : 14.5)
                case .code(let lang, let code): CodeBlockView(code: code, language: lang)
                }
            }
            if long {
                Button(expanded ? "Show less" : "Show the whole reply") { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } }
                    .font(Theme.caption).foregroundStyle(Theme.accent).buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8).padding(.horizontal, prominent ? 12 : 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(prominent ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 12))
        .overlay { if prominent { RoundedRectangle(cornerRadius: 12).stroke(Theme.line) } }
        .padding(.vertical, prominent ? 6 : 0)
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
                else { if !prose.isEmpty { out.append(.prose(prose.joined(separator: "\n"))); prose = [] }; lang = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces); inCode = true }
                continue
            }
            if inCode { code.append(line) } else { prose.append(line) }
        }
        if inCode { out.append(.code(lang, code.joined(separator: "\n"))) }
        if !prose.isEmpty { out.append(.prose(prose.joined(separator: "\n"))) }
        return out.filter { if case .prose(let p) = $0 { return !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }; return true }
    }
}

/// Markdown paragraphs: headings bold, bullets indented, inline markdown kept.
struct ProseText: View {
    let text: String
    var size: CGFloat = 14.5
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { Color.clear.frame(height: 2) }
                else if line.hasPrefix("#") {
                    Text(inline(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces))).font(.system(size: size + 1, weight: .semibold)).padding(.top, 4)
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
        .foregroundStyle(Theme.text).lineSpacing(2.5).textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// Fenced code: highlighted, horizontally scrollable, bounded height, copyable.
struct CodeBlockView: View {
    let code: String
    var language: String = ""
    @State private var expanded = false
    @State private var copied = false
    var lines: [String] { code.components(separatedBy: "\n") }
    var ext: String {
        let l = language.lowercased()
        let map = ["swift": "swift", "js": "js", "javascript": "js", "ts": "ts", "typescript": "ts", "tsx": "tsx", "python": "py", "py": "py", "bash": "sh", "sh": "sh", "shell": "sh", "zsh": "sh", "json": "json", "yaml": "yml", "yml": "yml", "gdscript": "gd", "html": "html", "css": "css", "kotlin": "kt", "diff": "diff"]
        return map[l] ?? "txt"
    }
    var body: some View {
        let isDiff = ext == "diff" || (lines.filter { $0.hasPrefix("+") || $0.hasPrefix("-") }.count > lines.count / 2 && lines.count > 3)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.textFaint)
                Spacer()
                Text("\(lines.count) line\(lines.count == 1 ? "" : "s")").font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
                Button { UIPasteboard.general.string = code; copied = true } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 12)).frame(width: 28, height: 24) }
                    .buttonStyle(.plain).foregroundStyle(Theme.textDim).accessibilityLabel(Text("Copy code"))
            }
            .padding(.leading, 10).padding(.trailing, 4).frame(height: 28)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
            if isDiff { DiffView(diff: code).frame(height: min(CGFloat(lines.count) * 19 + 16, expanded ? 900 : 320)) }
            else {
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
                Button(expanded ? "Collapse" : "Show all \(lines.count) lines") { expanded.toggle() }
                    .font(Theme.caption).foregroundStyle(Theme.accent).buttonStyle(.plain).padding(.horizontal, 10).padding(.bottom, 8)
            }
        }
        .background(Theme.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
    }
}

// MARK: - Routine steps

struct StepRow: View {
    let event: TimelineEvent
    var selected = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: event.icon).font(.system(size: 12)).foregroundStyle(event.tint == "other" ? Theme.textFaint : Theme.status(event.tint)).frame(width: 18)
            Text(stepTitle(event)).font(event.kind.contains("command") || event.kind == "agent.test" ? Theme.monoSmall : .system(size: 13))
                .foregroundStyle(Theme.textDim).lineLimit(2).truncationMode(.middle)
            Spacer(minLength: 6)
            Text(Fmt.time(event.ts)).font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
        }
        .padding(.vertical, 5).padding(.horizontal, 6)
        .background(selected ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }
}

/// Shell prefixes and "Finished:" labels are noise in a list of steps.
func stepTitle(_ e: TimelineEvent) -> String {
    var t = e.title
    for p in ["$ ", "Finished: ", "Running tests: "] where t.hasPrefix(p) { t = String(t.dropFirst(p.count)) }
    return t
}

struct StepsGroup: View {
    let events: [TimelineEvent]
    let select: (TimelineEvent) -> Void
    var selectedId: String?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 9) {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textFaint)
                        .rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 18)
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
                    ForEach(events, id: \.stableId) { e in StepRow(event: e, selected: selectedId == e.stableId).onTapGesture { select(e) } }
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

struct EditsGroup: View {
    let events: [TimelineEvent]
    let select: (TimelineEvent) -> Void
    struct EditedFile: Identifiable { let id: String; let name: String; let event: TimelineEvent; let added: Int; let removed: Int }
    var files: [EditedFile] {
        var seen = Set<String>()
        var out: [EditedFile] = []
        for e in events.reversed() {
            let p = e.detail?["path"]?.string ?? e.title
            guard seen.insert(p).inserted else { continue }
            var a = 0, r = 0
            if let d = e.detail?["diff"]?.string {
                for l in d.split(separator: "\n") { if l.hasPrefix("+") && !l.hasPrefix("+++") { a += 1 } else if l.hasPrefix("-") && !l.hasPrefix("---") { r += 1 } }
            } else {
                for x in e.detail?["edits"]?.array ?? [] {
                    a += (x["new"]?.string ?? "").split(separator: "\n", omittingEmptySubsequences: false).count
                    r += (x["old"]?.string ?? "").split(separator: "\n", omittingEmptySubsequences: false).count
                }
            }
            out.append(EditedFile(id: e.stableId, name: (p as NSString).lastPathComponent, event: e, added: a, removed: r))
        }
        return out.reversed()
    }
    var body: some View {
        let fs = files
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Image(systemName: "pencil.line").font(.system(size: 12)).foregroundStyle(Theme.blue).frame(width: 18)
                Text("Edited \(fs.count) file\(fs.count == 1 ? "" : "s")").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textDim)
                Spacer()
                if let l = events.last { Text(Fmt.time(l.ts)).font(.system(size: 11.5)).foregroundStyle(Theme.textFaint) }
            }
            FlowLayout(spacing: 6) {
                ForEach(fs) { f in
                    Button { select(f.event) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "doc.text").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                            Text(f.name).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.text).lineLimit(1)
                            if f.added > 0 { Text("+\(f.added)").font(.system(size: 11.5, weight: .medium, design: .monospaced)).foregroundStyle(Theme.green) }
                            if f.removed > 0 { Text("−\(f.removed)").font(.system(size: 11.5, weight: .medium, design: .monospaced)).foregroundStyle(Theme.red) }
                        }
                        .padding(.horizontal, 9).frame(height: 28)
                        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("\(f.name), \(f.added) added, \(f.removed) removed. Show changes"))
                }
            }
            .padding(.leading, 27)
        }
        .padding(.vertical, 6).padding(.horizontal, 6)
    }
}

/// Wrapping row of chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height); maxX = max(maxX, x)
        }
        return CGSize(width: min(maxX, width), height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: min(s.width, bounds.width), height: s.height))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}

// MARK: - Results

struct TestCard: View {
    let event: TimelineEvent
    let select: (TimelineEvent) -> Void
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
                Button(showLog ? "Hide log" : "Show log") { withAnimation(.easeOut(duration: 0.15)) { showLog.toggle() } }.font(Theme.caption).foregroundStyle(Theme.accent).buttonStyle(.plain)
                if showLog { LogBox(text: output, maxHeight: 280) }
            }
        }
        .padding(12)
        .background((passed ? Theme.green : Theme.red).opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke((passed ? Theme.green : Theme.red).opacity(0.25)))
        .padding(.vertical, 5)
        .contextMenu { Button { select(event) } label: { Label("Show details", systemImage: "sidebar.right") } }
    }
}

struct FailureCard: View {
    let event: TimelineEvent
    let select: (TimelineEvent) -> Void
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
                Button(showLog ? "Less" : "Full output") { withAnimation(.easeOut(duration: 0.15)) { showLog.toggle() } }.font(Theme.caption).foregroundStyle(Theme.accent).buttonStyle(.plain).padding(.leading, 27)
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 6)
        .background(Theme.red.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .padding(.vertical, 2)
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
        .background(Theme.raised.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ErrorCard: View {
    let event: TimelineEvent
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.red)
            VStack(alignment: .leading, spacing: 3) {
                Text("Error").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.red)
                Text(event.detail?["message"]?.string ?? event.detail?["text"]?.string ?? event.title).font(.system(size: 13.5)).foregroundStyle(Theme.text).lineLimit(6).textSelection(.enabled)
                if let out = event.detail?["output"]?.string, !out.isEmpty { LogBox(text: out, maxHeight: 160) }
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
        .padding(.vertical, 7).padding(.horizontal, 6)
        .background(Theme.yellow.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .padding(.vertical, 2).contentShape(Rectangle())
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

// MARK: - Images

/// Screenshot or image the agent produced or viewed: a real thumbnail at its
/// own aspect ratio, tap to enlarge.
struct ImageCard: View {
    let event: TimelineEvent
    @Environment(AppModel.self) private var app
    struct Source { let path: String; let query: [String: String?]; let full: String; let fullQuery: [String: String?] }
    @State private var source: Source?
    @State private var missing = false
    @State private var zoom = false

    var path: String? { event.detail?["path"]?.string }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Image(systemName: "photo").font(.system(size: 12)).foregroundStyle(Theme.purple).frame(width: 18)
                Text(event.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textDim).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(Fmt.time(event.ts)).font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
            }
            Group {
                if let s = source {
                    Button { zoom = true } label: {
                        AuthImage(path: s.path, query: s.query, contentMode: .fit)
                            .frame(maxWidth: 460, maxHeight: 280, alignment: .leading)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Enlarge \(event.title)"))
                } else if missing {
                    Text((path as NSString?)?.lastPathComponent ?? "Image").font(Theme.monoSmall).foregroundStyle(Theme.textFaint)
                } else {
                    RoundedRectangle(cornerRadius: 9).fill(Theme.raised).frame(width: 220, height: 130).overlay(ProgressView().controlSize(.small))
                }
            }
            .padding(.leading, 27)
        }
        .padding(.vertical, 6).padding(.horizontal, 6)
        .task(id: event.stableId) { await resolve() }
        .sheet(isPresented: $zoom) {
            if let s = source {
                ZStack(alignment: .topTrailing) {
                    Color(Theme.terminalBg).ignoresSafeArea()
                    FullImage(path: s.full, query: s.fullQuery)
                    Button { zoom = false } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 28)).foregroundStyle(.white.opacity(0.85)).padding(16) }
                        .accessibilityLabel(Text("Close"))
                }
            }
        }
    }

    func resolve() async {
        guard let path else { missing = true; return }
        if let loc = app.locate(path) {
            source = Source(path: "/api/projects/\(loc.project.id)/thumb", query: ["path": loc.rel, "w": "920"], full: "/api/projects/\(loc.project.id)/raw", fullQuery: ["path": loc.rel]); return
        }
        for _ in 0..<4 {
            if let list = try? await app.client.get("/api/screenshots", ["session": event.session, "limit": "100"], as: [Screenshot].self),
               let s = list.first(where: { $0.path == path }) {
                source = Source(path: "/api/screenshots/\(s.id)/image", query: ["w": "920"], full: "/api/screenshots/\(s.id)/image", fullQuery: [:]); return
            }
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
        missing = true
    }
}

struct FullImage: View {
    let path: String
    let query: [String: String?]
    @Environment(AppModel.self) private var app
    @State private var image: UIImage?
    var body: some View {
        Group { if let image { ZoomableImage(image: image) } else { ProgressView().tint(.white) } }
            .task(id: path) { image = await ImageCache.shared.image(client: app.client, path: path, query: query) }
    }
}
