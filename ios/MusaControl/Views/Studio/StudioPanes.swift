import SwiftUI

private typealias M = StudioMetrics

// MARK: - Window controls

/// What a window's title bar can do. Set by PaneHost, read by StudioWindow.
struct PaneControls {
    let kind: PaneKind
    let pinned: Bool
    let floating: Bool
    let primary: Bool
    let close: () -> Void
    let minimize: () -> Void
    let togglePin: () -> Void
    let toggleFloat: () -> Void
    let bringForward: () -> Void
    let dragChanged: (CGSize) -> Void
    let dragEnded: (CGSize) -> Void
}

private struct PaneControlsKey: EnvironmentKey { static let defaultValue: PaneControls? = nil }
extension EnvironmentValues {
    var paneControls: PaneControls? {
        get { self[PaneControlsKey.self] }
        set { self[PaneControlsKey.self] = newValue }
    }
}

/// Places one window on the stage and gives it its controls. Dragging the
/// title bar pops it out where you drop it; a popped-out window can be
/// resized from its corner and docked back. Moves are animated so the
/// window never jumps when the board re-tiles around it.
struct PaneHost<Content: View>: View {
    let kind: PaneKind
    let frame: CGRect          // in tiling-area coordinates
    let origin: CGPoint        // tiling area's origin on the stage
    let area: CGSize
    let floating: Bool
    let primary: Bool
    let d: StudioDirector
    @ViewBuilder var content: Content
    @State private var drag: CGSize = .zero
    @State private var grow: CGSize = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var pinned: Bool { d.board.pane(kind).pinned != nil }
    var spring: Animation? { reduceMotion ? nil : .spring(duration: 0.5, bounce: 0.12) }

    var body: some View {
        let w = max(220, frame.width + grow.width), h = max(140, frame.height + grow.height)
        content
            .environment(\.paneControls, controls)
            .frame(width: w, height: h)
            .overlay(alignment: .bottomTrailing) { if floating { resizeHandle } }
            .scaleEffect(drag == .zero ? 1 : 1.015)
            .shadow(color: Theme.shadow.opacity(floating || drag != .zero ? 1 : 0), radius: floating ? 26 : 0, y: floating ? 12 : 0)
            .studioRegion(kind.region, d)
            .position(x: origin.x + frame.minX + w / 2, y: origin.y + frame.minY + h / 2)
            .offset(drag)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(label))
            .accessibilityIdentifier("studio.window.\(kind.rawValue)")
            .accessibilityAction(named: Text(pinned ? "Unpin" : "Pin")) { controls.togglePin() }
            .accessibilityAction(named: Text(floating ? "Dock" : "Pop out")) { controls.toggleFloat() }
            .accessibilityAction(named: Text("Minimise")) { controls.minimize() }
    }

    var label: String {
        var parts = ["\(kind.title) window"]
        if primary { parts.append("in focus") }
        if pinned { parts.append("pinned") }
        if floating { parts.append("popped out") }
        return parts.joined(separator: ", ")
    }

    var controls: PaneControls {
        PaneControls(
            kind: kind, pinned: pinned, floating: floating, primary: primary,
            close: { d.userTouched(); withAnimation(spring) { d.board.close(kind) } },
            minimize: { d.userTouched(); withAnimation(spring) { d.board.minimize(kind) } },
            togglePin: {
                d.userTouched()
                Device.tap()
                withAnimation(spring) { d.board.togglePin(kind, slot: d.board.slot(of: kind, in: d.boardSize)) }
            },
            toggleFloat: {
                d.userTouched()
                withAnimation(spring) {
                    if floating { d.board.dock(kind) }
                    else {
                        let w = min(area.width * 0.55, 620), h = min(area.height * 0.6, 460)
                        let i = CGFloat(PaneKind.allCases.firstIndex(of: kind) ?? 0)
                        d.board.float(kind, frame: CGRect(x: (area.width - w) / 2 + i * 14 - 40, y: (area.height - h) / 2 + i * 10 - 30, width: w, height: h))
                    }
                }
            },
            bringForward: { d.userTouched(); withAnimation(spring) { d.board.bringForward(kind) } },
            dragChanged: { t in if drag == .zero { d.userTouched() }; drag = t },
            dragEnded: { t in
                d.userTouched()
                let target = CGRect(x: frame.minX + t.width, y: frame.minY + t.height, width: frame.width, height: frame.height)
                // Position and offset animate together, so the window stays
                // exactly where it was dropped while the others re-tile.
                withAnimation(spring) {
                    d.board.float(kind, frame: target)
                    drag = .zero
                }
            })
    }

    var resizeHandle: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 10, weight: .bold)).rotationEffect(.degrees(90))
            .foregroundStyle(Theme.textFaint)
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("stage"))
                .onChanged { v in d.userTouched(); grow = v.translation }
                .onEnded { v in
                    let f = CGRect(x: frame.minX, y: frame.minY, width: frame.width + v.translation.width, height: frame.height + v.translation.height)
                    var t = Transaction(); t.disablesAnimations = true
                    withTransaction(t) { d.board.float(kind, frame: f); grow = .zero }
                })
            .accessibilityLabel(Text("Resize"))
    }
}

/// Windows the board has no room for (or you minimised), as chips.
struct StudioDock: View {
    let kinds: [PaneKind]
    let d: StudioDirector
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.compactLayout) private var compact

    var body: some View {
        HStack(spacing: 6) {
            ForEach(kinds) { k in
                Button {
                    d.userTouched()
                    Device.tap()
                    withAnimation(reduceMotion ? nil : .spring(duration: 0.5, bounce: 0.12)) { d.board.bringForward(k) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: k.icon).font(.system(size: 11, weight: .semibold))
                        if !compact { Text(k.title).font(.system(size: 12, weight: .medium)).lineLimit(1).fixedSize() }
                        if let b = badge(k) { Text(b.0).font(.system(size: 10.5, weight: .bold).monospacedDigit()).foregroundStyle(b.1) }
                    }
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, compact ? 9 : 11).frame(minWidth: compact ? 36 : nil).frame(height: 32)
                    .background(Theme.surface, in: Capsule())
                    .overlay(Capsule().stroke(Theme.lineStrong))
                    .contentShape(Capsule())
                }
                .buttonStyle(DeckPress())
                .accessibilityLabel(Text("Show \(k.title)"))
                .accessibilityIdentifier("studio.dock.\(k.rawValue)")
                .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .padding(5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Theme.line))
        .shadow(color: Theme.shadow, radius: 12, y: 4)
    }

    func badge(_ k: PaneKind) -> (String, Color)? {
        switch k {
        case .tests:
            guard let t = d.tests, !t.running else { return nil }
            if let f = t.failed, f > 0 { return ("\(f)✕", Theme.red) }
            if let p = t.passed { return ("\(p)✓", Theme.green) }
            return nil
        case .runs:
            let n = d.runs.filter(\.running).count
            return n > 0 ? ("\(n)", Theme.blue) : nil
        case .lightbox: return d.photos.isEmpty ? nil : ("\(d.photos.count)", Theme.textDim)
        case .files: return d.heat.isEmpty ? nil : ("\(d.heat.count)", Theme.textDim)
        default: return nil
        }
    }
}

// MARK: - Thinking

struct ThoughtPane: View {
    let d: StudioDirector
    let agent: Agent?
    var thinking: Bool { !d.busy && agent?.status == "working" }
    var body: some View {
        StudioWindow(title: !d.thoughtDone ? "Writing" : thinking ? "Thinking" : "Last note", icon: "brain", active: d.focus == .thought || !d.thoughtDone) {
            if !d.thoughtDone || thinking { TypingDots(color: agent?.tint ?? Theme.accent, size: 4) }
        } content: {
            Group {
                if d.thought.isEmpty {
                    Text(thinking ? "Working out what to do next…" : "Nothing said yet.").font(.system(size: 13)).foregroundStyle(Theme.textFaint)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ScrollView {
                        StreamingText(text: d.thought, done: d.thoughtDone, tint: agent?.tint ?? Theme.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .defaultScrollAnchor(.bottom)
                    .scrollIndicators(.hidden)
                }
            }
            .padding(12)
        }
    }
}

/// The agent's own words as they stream in; the newest few words are
/// brighter and settle, the caret follows the end.
struct StreamingText: View {
    let text: String
    let done: Bool
    let tint: Color
    var body: some View {
        if done {
            Text(text).font(.system(size: 13.5)).foregroundStyle(Theme.text)
        } else {
            let words = text.split(separator: " ", omittingEmptySubsequences: false)
            let settled = words.dropLast(3).joined(separator: " ")
            let fresh = words.suffix(3).joined(separator: " ")
            (Text(settled + (settled.isEmpty ? "" : " ")).foregroundColor(Theme.text)
             + Text(fresh).foregroundColor(tint)
             + Text(" ▍").foregroundColor(tint))
                .font(.system(size: 13.5))
        }
    }
}

// MARK: - Plan

/// The plan as a progress rail: done steps filled, the current one lit.
struct PlanPane: View {
    let steps: [PlanStep]
    var body: some View {
        let done = steps.filter { $0.status == "completed" }.count
        StudioWindow(title: "Plan", icon: "list.bullet") {
            Text("\(done)/\(steps.count)").font(.system(size: 11.5, weight: .semibold).monospacedDigit())
        } content: {
            if steps.isEmpty {
                Text("No plan yet").font(Theme.caption).foregroundStyle(Theme.textFaint).padding(12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(steps.enumerated()), id: \.element.id) { i, s in
                            PlanRailRow(step: s, first: i == 0, last: i == steps.count - 1, prevDone: i > 0 && steps[i - 1].status == "completed")
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                }
                .scrollIndicators(.hidden)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Plan, \(done) of \(steps.count) done. " + (steps.first { $0.status == "in_progress" }.map { "Now: \($0.text)" } ?? "")))
    }
}

struct PlanRailRow: View {
    let step: PlanStep
    let first: Bool
    let last: Bool
    let prevDone: Bool
    var done: Bool { step.status == "completed" }
    var current: Bool { step.status == "in_progress" }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    Rectangle().fill(first ? .clear : prevDone ? Theme.green : Theme.lineStrong).frame(width: 2, height: 8)
                    Rectangle().fill(last ? .clear : done ? Theme.green : Theme.lineStrong).frame(width: 2).frame(maxHeight: .infinity)
                }
                ZStack {
                    if done {
                        Circle().fill(Theme.green)
                        Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(Theme.onAccent)
                    } else if current {
                        Circle().fill(Theme.blue.opacity(0.18))
                        Circle().stroke(Theme.blue, lineWidth: 2)
                        Circle().fill(Theme.blue).padding(4.5)
                    } else {
                        Circle().fill(Theme.surface)
                        Circle().stroke(Theme.lineStrong, lineWidth: 1.5)
                    }
                }
                .frame(width: 16, height: 16)
                .padding(.top, 1)
                .symbolEffect(.pulse, isActive: current)
            }
            .frame(width: 16)
            Text(step.text)
                .font(.system(size: 13, weight: current ? .semibold : .regular))
                .foregroundStyle(done ? Theme.textFaint : Theme.text)
                .strikethrough(done, color: Theme.textFaint.opacity(0.5))
                .padding(.vertical, current ? 5 : 2).padding(.horizontal, current ? 8 : 0)
                .background(current ? Theme.blue.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .padding(.bottom, 10)
                .fixedSize(horizontal: false, vertical: true)
        }
        .animation(.spring(duration: 0.4, bounce: 0.3), value: step.status)
    }
}

// MARK: - Tests

/// Pass/fail matrix: one cell per test the runner reported, filling in as
/// the output streams. Totals and failure messages are quoted from the output.
struct TestsPane: View {
    let run: TestRun?
    var body: some View {
        StudioWindow(title: "Tests", icon: "checklist", active: run?.running == true) {
            if let r = run {
                if r.running { ProgressView().controlSize(.mini) }
                else if let ok = r.ok { Image(systemName: ok ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(ok ? Theme.green : Theme.red) }
            }
        } content: {
            if let r = run {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        if let p = r.passed { TestCount(value: p, label: "passed", color: Theme.green) }
                        if let f = r.failed { TestCount(value: f, label: "failed", color: f > 0 ? Theme.red : Theme.textFaint) }
                        if let s = r.skipped, s > 0 { TestCount(value: s, label: "skipped", color: Theme.textFaint) }
                        if r.running { Text("Running…").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.blue) }
                        Spacer(minLength: 0)
                    }
                    Text(r.command).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
                    if r.cellCount > 0 {
                        TestMatrix(run: r).frame(maxWidth: .infinity, minHeight: 30, maxHeight: .infinity)
                    } else if !r.running {
                        Text(r.summary ?? "The runner didn't print per-test results.").font(.system(size: 12)).foregroundStyle(Theme.textDim)
                        Spacer(minLength: 0)
                    } else {
                        Spacer(minLength: 0)
                    }
                    if !r.failures.isEmpty && r.revealed >= r.cellCount {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(r.failures.prefix(3).enumerated()), id: \.offset) { _, f in
                                Text(f).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.red).lineLimit(3)
                                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Theme.removedBg, in: RoundedRectangle(cornerRadius: 7))
                            }
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(12)
                .animation(.easeOut(duration: 0.3), value: r.revealed >= r.cellCount)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(accessibility(r)))
            } else {
                Text("No test run yet").font(Theme.caption).foregroundStyle(Theme.textFaint).padding(12)
            }
        }
    }

    func accessibility(_ r: TestRun) -> String {
        if r.running { return "Tests running: \(r.command)" }
        var s = "\(r.cellCount) tests"
        if let p = r.passed { s += ", \(p) passed" }
        if let f = r.failed { s += ", \(f) failed" }
        if let first = r.failures.first { s += ". First failure: \(first)" }
        return s
    }
}

struct TestCount: View {
    let value: Int
    let label: String
    let color: Color
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(value)").font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(color)
                .contentTransition(.numericText(value: Double(value)))
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textDim)
        }
    }
}

struct TestMatrix: View {
    let run: TestRun
    var body: some View {
        Canvas { gc, size in Self.draw(&gc, size: size, run: run) }
            .animation(.easeOut(duration: 0.15), value: run.revealed)
    }

    /// Cells shrink to fit every test in the space the window has.
    static func cell(for n: Int, in size: CGSize) -> CGFloat {
        guard n > 0 else { return 14 }
        let s = (size.width * size.height / CGFloat(n)).squareRoot() - 3
        return min(16, max(4, s.rounded(.down)))
    }

    static func draw(_ gc: inout GraphicsContext, size: CGSize, run: TestRun) {
        let n = run.cellCount
        let c = cell(for: n, in: size)
        let step: CGFloat = c + 3
        let cols = max(1, Int((size.width + 3) / step))
        let radius: CGFloat = min(3, c / 3)
        for i in 0..<n {
            let row = i / cols, col = i % cols
            let y = CGFloat(row) * step
            if y + c > size.height { break }
            let r = CGRect(x: CGFloat(col) * step, y: y, width: c, height: c)
            let path = Path(roundedRect: r, cornerRadius: radius)
            guard i < run.revealed else {
                gc.stroke(path, with: .color(Theme.lineStrong), lineWidth: 1)
                continue
            }
            let color: Color
            switch run.cell(i) {
            case .pass: color = Theme.green
            case .fail: color = Theme.red
            case .skip: color = Theme.textFaint
            }
            gc.fill(path, with: .color(color.opacity(i == run.revealed - 1 && run.revealed < n ? 1 : 0.85)))
            if i == run.revealed - 1 && run.revealed < n {
                // Leading edge of the fill: a soft bloom.
                gc.fill(Path(roundedRect: r.insetBy(dx: -3, dy: -3), cornerRadius: radius + 2), with: .color(color.opacity(0.25)))
            }
        }
    }
}

// MARK: - Runs

/// Every command the agent ran: a ring for how long it took (only when
/// the events timed it), coloured by how it exited.
struct RunsPane: View {
    let runs: [CommandRun]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let longest = runs.compactMap(\.duration).max() ?? 0
        let live = runs.last { $0.running }
        StudioWindow(title: live?.build == true ? "Build" : "Runs", icon: live?.build == true ? "hammer" : "timer", active: live != nil) {
            if !runs.isEmpty { Text("\(runs.count)").font(.system(size: 11.5, weight: .semibold).monospacedDigit()) }
        } content: {
            VStack(spacing: 0) {
                if let live { RunHero(run: live, animate: !reduceMotion).padding(12).transition(.move(edge: .top).combined(with: .opacity)) }
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(runs.reversed().filter { $0.id != live?.id }) { r in
                            RunRow(run: r, longest: longest)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                }
                .scrollIndicators(.hidden)
                if runs.isEmpty {
                    Text("No commands yet").font(Theme.caption).foregroundStyle(Theme.textFaint).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .animation(.snappy(duration: 0.3), value: runs)
        }
    }
}

struct RunHero: View {
    let run: CommandRun
    let animate: Bool
    var body: some View {
        HStack(spacing: 14) {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !animate)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                ZStack {
                    Circle().stroke(Theme.lineStrong, lineWidth: 4)
                    Circle().trim(from: 0, to: 0.28)
                        .stroke(Theme.blue, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(animate ? t * 220 : -90))
                }
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(run.build ? "Building" : run.test ? "Testing" : "Running")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.blue)
                Text(run.command).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text("\(Fmt.duration(max(0, ctx.date.timeIntervalSince1970 - run.start / 1000))) so far")
                        .font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Theme.textDim)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Theme.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

struct RunRow: View {
    let run: CommandRun
    let longest: Double

    var color: Color {
        guard let ok = run.ok else { return run.lost ? Theme.textFaint : Theme.blue }
        return ok ? Theme.green : Theme.red
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().stroke(Theme.lineStrong, lineWidth: 3)
                if let d = run.duration {
                    Circle().trim(from: 0, to: max(0.04, CommandRun.ring(d, longest: longest)))
                        .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                } else {
                    Circle().fill(color.opacity(0.85)).padding(7)
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(run.command).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if let d = run.duration { Text(d < 1 ? String(format: "%.0f ms", d * 1000) : String(format: "%.1f s", d)) }
                    else if run.lost { Text("no result reported") }
                    if run.test { Text("tests") }
                    if run.build { Text("build") }
                }
                .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.textFaint)
            }
            Spacer(minLength: 4)
            if let ok = run.ok {
                Text(run.exit.map { "exit \($0)" } ?? (ok ? "ok" : "failed"))
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(color)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(color.opacity(0.13), in: Capsule())
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(spoken))
    }

    var spoken: String {
        let state: String
        if let ok = run.ok { state = ok ? "succeeded" : "failed" } else { state = run.lost ? "no result" : "running" }
        var s = run.command + ", " + state
        if let d = run.duration { s += String(format: ", %.1f seconds", d) }
        return s
    }
}

// MARK: - Diff

/// The latest edit, split: what was there, what replaced it.
struct DiffPane: View {
    let split: DiffSplit?
    @Environment(\.stageAnimates) private var animates
    var body: some View {
        StudioWindow(title: split.map { "Diff — \(($0.path as NSString).lastPathComponent)" } ?? "Diff", icon: "arrow.left.arrow.right") {
            if let s = split {
                HStack(spacing: 6) {
                    Text("+\(s.added)").foregroundStyle(Theme.green)
                    Text("−\(s.removed)").foregroundStyle(Theme.red)
                }
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
        } content: {
            if let s = split {
                GeometryReader { geo in
                    let side = geo.size.width >= 380
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(s.hunks) { h in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("line \(h.line + 1)").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.textFaint)
                                    if side {
                                        HStack(alignment: .top, spacing: 6) {
                                            DiffColumn(lines: h.before, added: false, start: h.line)
                                            DiffColumn(lines: h.after, added: true, start: h.line)
                                        }
                                    } else {
                                        DiffColumn(lines: h.before, added: false, start: h.line)
                                        DiffColumn(lines: h.after, added: true, start: h.line)
                                    }
                                }
                            }
                        }
                        .padding(10)
                        .id(s.id)
                        .transition(.codeLine(Theme.green, animates: animates))
                    }
                    .scrollIndicators(.hidden)
                }
            } else {
                Text("No edits yet").font(Theme.caption).foregroundStyle(Theme.textFaint).padding(12)
            }
        }
    }
}

struct DiffColumn: View {
    let lines: [String]
    let added: Bool
    let start: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if lines.isEmpty {
                Text(added ? "(removed)" : "(new lines)").font(.system(size: 11)).foregroundStyle(Theme.textFaint).padding(6)
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                HStack(spacing: 6) {
                    Text(added ? "+" : "−").foregroundStyle(added ? Theme.green : Theme.red).frame(width: 8)
                    Text(l.isEmpty ? " " : l).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11.5, design: .monospaced))
                .padding(.horizontal, 6).padding(.vertical, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(added ? Theme.addedBg : Theme.removedBg, in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Files touched

/// Every file the agent read or edited this session, as a treemap: area is
/// how much it was touched (edits count triple), colour is how recently.
struct FilesPane: View {
    let heat: [String: FileHeat]
    var body: some View {
        let top = HeatMap.top(heat)
        let newest = top.map(\.last).max() ?? 0
        StudioWindow(title: "Files touched", icon: "square.grid.3x3.fill") {
            if !heat.isEmpty { Text("\(heat.count)").font(.system(size: 11.5, weight: .semibold).monospacedDigit()) }
        } content: {
            if top.isEmpty {
                Text("Files appear here as the agent reads and edits them").font(Theme.caption).foregroundStyle(Theme.textFaint).padding(12)
            } else {
                GeometryReader { geo in
                    let rects = DeckLayout.squarify(top.map(\.weight), in: CGRect(origin: .zero, size: geo.size))
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(top.enumerated()), id: \.element.id) { i, f in
                            let r = rects[i].insetBy(dx: 1.5, dy: 1.5)
                            HeatCell(file: f, recency: HeatMap.recency(f, newest: newest), size: r.size)
                                .frame(width: max(0, r.width), height: max(0, r.height))
                                .position(x: r.midX, y: r.midY)
                        }
                    }
                    .animation(.spring(duration: 0.5, bounce: 0.1), value: top)
                }
                .padding(8)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Files touched: " + top.prefix(8).map { "\(($0.path as NSString).lastPathComponent), \($0.edits) edits, \($0.reads) reads" }.joined(separator: "; ")))
            }
        }
    }
}

struct HeatCell: View {
    let file: FileHeat
    let recency: Double
    let size: CGSize
    var body: some View {
        let edited = file.edits > 0
        let base = edited ? Theme.accent : Theme.blue
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5).fill(base.opacity((edited ? 0.2 : 0.1) + (edited ? 0.5 : 0.3) * recency))
            RoundedRectangle(cornerRadius: 5).stroke(base.opacity(0.25 + 0.5 * recency), lineWidth: recency > 0.9 ? 1.5 : 0.5)
            if size.width > 56 && size.height > 24 {
                VStack(alignment: .leading, spacing: 1) {
                    Text((file.path as NSString).lastPathComponent).font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                    if size.height > 40 {
                        HStack(spacing: 6) {
                            if file.edits > 0 { Label("\(file.edits)", systemImage: "pencil") }
                            if file.reads > 0 { Label("\(file.reads)", systemImage: "eye") }
                        }
                        .font(.system(size: 9.5, weight: .medium)).foregroundStyle(Theme.textDim)
                        .labelStyle(.titleAndIcon)
                    }
                }
                .padding(5)
            }
        }
    }
}

// MARK: - Screenshots

struct LightboxPane: View {
    let photos: [StudioPhoto]
    @State private var picked: String?
    var body: some View {
        let shown = photos.first { $0.id == picked } ?? photos.last
        StudioWindow(title: shown?.title ?? "Screenshots", icon: "photo") {
            if photos.count > 1 { Text("\(photos.count)").font(.system(size: 11.5, weight: .semibold).monospacedDigit()) }
        } content: {
            if let p = shown {
                VStack(spacing: 8) {
                    AuthImage(path: p.path, query: p.query, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .id(p.id)
                        .transition(.opacity)
                    if photos.count > 1 {
                        ScrollView(.horizontal) {
                            HStack(spacing: 6) {
                                ForEach(photos.reversed()) { q in
                                    Button { withAnimation(.easeOut(duration: 0.2)) { picked = q.id } } label: {
                                        AuthImage(path: q.path, query: q.query, contentMode: .fill)
                                            .frame(width: 52, height: 36).clipShape(RoundedRectangle(cornerRadius: 4))
                                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(q.id == p.id ? Theme.accent : Theme.line, lineWidth: q.id == p.id ? 2 : 1))
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(Text(q.title))
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                        .frame(height: 38)
                    }
                }
                .padding(10)
            } else {
                Text("No screenshots yet").font(Theme.caption).foregroundStyle(Theme.textFaint).padding(12)
            }
        }
        .onChange(of: photos.last?.id) { _, _ in picked = nil }
    }
}

// MARK: - Minimap

/// The whole open file in miniature: changed lines lit, the visible part
/// framed, the caret marked.
struct EditorMinimap: View {
    let d: StudioDirector
    var body: some View {
        let lines = d.lines, scrollY = d.scrollY, visible = d.visibleLines, caret = d.caret?.line, read = d.readLine
        Canvas { gc, size in Self.draw(&gc, size: size, lines: lines, scrollY: scrollY, visible: visible, caret: caret, read: read) }
            .background(Theme.raised.opacity(0.25))
            .overlay(alignment: .leading) { Rectangle().fill(Theme.line).frame(width: 1) }
            .accessibilityHidden(true)
    }

    static func draw(_ gc: inout GraphicsContext, size: CGSize, lines: [EdLine], scrollY: CGFloat, visible: Int, caret: Int?, read: Int?) {
        let n = lines.count
        guard n > 0 else { return }
        let h: CGFloat = min(3, max(0.6, (size.height - 8) / CGFloat(n)))
        let stride = max(1, Int((CGFloat(n) * h) / max(1, size.height - 8)) + (CGFloat(n) * h > size.height ? 1 : 0))
        let x0: CGFloat = 6
        let maxW: CGFloat = size.width - 10
        var i = 0
        while i < n {
            let l = lines[i]
            let y = 4 + CGFloat(i / stride) * h
            let indent = CGFloat(l.text.prefix(while: { $0 == " " }).count)
            let len = CGFloat(l.text.count) - indent
            if len > 0 {
                let r = CGRect(x: x0 + min(maxW * 0.5, indent * 0.6), y: y, width: max(2, min(maxW - indent * 0.6, len * 0.55)), height: max(0.6, h - 0.5))
                let c: Color
                switch l.mark {
                case .added: c = Theme.green
                case .typing: c = Theme.accent
                case .selected: c = Theme.blue
                case .none: c = Theme.textFaint.opacity(0.45)
                }
                gc.fill(Path(r), with: .color(c))
                if l.mark != .none {
                    gc.fill(Path(CGRect(x: 0, y: y - 0.5, width: 3, height: h + 1)), with: .color(c))
                }
            }
            i += stride
        }
        let top = scrollY / M.lineH
        let vy = 4 + top / CGFloat(stride) * h
        let vh = max(8, CGFloat(visible) / CGFloat(stride) * h)
        let view = CGRect(x: 1, y: vy, width: size.width - 2, height: vh)
        gc.fill(Path(roundedRect: view, cornerRadius: 3), with: .color(Theme.accent.opacity(0.08)))
        gc.stroke(Path(roundedRect: view, cornerRadius: 3), with: .color(Theme.accent.opacity(0.35)), lineWidth: 1)
        for (line, color) in [(caret, Theme.accent), (read, Theme.blue)] {
            guard let line else { continue }
            let y = 4 + CGFloat(line / stride) * h
            gc.fill(Path(CGRect(x: 0, y: y - 1, width: size.width, height: 2)), with: .color(color.opacity(0.9)))
        }
    }
}
