import SwiftUI

// Timeline scrubber: the agent's session as a track of real events. Drag or
// tap to rewind, replay at 1×–8×, jump between edits, commands and failures,
// and snap back to Live. Replays use the same director scenes as live play,
// fed from the session's history: nothing on screen is regenerated.

struct ScrubMark: Identifiable, Equatable {
    enum Kind: Equatable { case edit, read, command, test, failure, message, plan, image, prompt, done, other }
    let id: Int          // index in the session history
    let kind: Kind
    let title: String
    let ts: Double
}

enum Scrub {
    static func kind(_ e: TimelineEvent) -> ScrubMark.Kind {
        switch e.kind {
        case "agent.edit": return .edit
        case "agent.read": return .read
        case "agent.command", "agent.command_done":
            if Feed.isTestResult(e) { return AgentPulse.ok(e) ? .test : .failure }
            return .command
        case "agent.test":
            if Feed.isTestResult(e) && !AgentPulse.ok(e) { return .failure }
            return .test
        case "agent.command_failed", "agent.error": return .failure
        case "agent.message": return .message
        case "agent.plan": return .plan
        case "agent.image": return .image
        case "agent.prompt": return .prompt
        case "agent.done": return .done
        default: return .other
        }
    }

    static func marks(_ history: [TimelineEvent]) -> [ScrubMark] {
        history.enumerated().map { i, e in ScrubMark(id: i, kind: kind(e), title: e.title, ts: e.ts) }
    }

    /// The next (or previous) mark after `index` that matches.
    static func next(_ marks: [ScrubMark], after index: Int, _ match: (ScrubMark.Kind) -> Bool) -> Int? {
        marks.first { $0.id > index && match($0.kind) }?.id
    }
    static func previous(_ marks: [ScrubMark], before index: Int, _ match: (ScrubMark.Kind) -> Bool) -> Int? {
        marks.last { $0.id < index && match($0.kind) }?.id
    }

    /// Track position ↔ history index (evenly spaced by event, not by time,
    /// so long pauses don't squash the busy parts).
    static func index(at x: CGFloat, width: CGFloat, count: Int) -> Int {
        guard count > 1, width > 0 else { return 0 }
        return Int((min(max(0, x), width) / width * CGFloat(count - 1)).rounded())
    }
    static func x(of index: Int, width: CGFloat, count: Int) -> CGFloat {
        guard count > 1 else { return width }
        return CGFloat(min(max(0, index), count - 1)) / CGFloat(count - 1) * width
    }

    static let rates: [Double] = [1, 2, 4, 8]
    static func nextRate(_ r: Double) -> Double { rates.first { $0 > r } ?? rates[0] }
}

struct StudioScrubber: View {
    let d: StudioDirector
    @Environment(\.compactLayout) private var compact
    @State private var dragIndex: Int?

    var live: Bool { d.playback == .live }
    var playing: Bool { if case .replay(let p) = d.playback { return p } else { return false } }

    var body: some View {
        let marks = d.marks
        HStack(spacing: compact ? 4 : 8) {
            Button { jump(back: true) } label: { Image(systemName: "backward.end.fill") }
                .buttonStyle(ScrubButton())
                .disabled(Scrub.previous(marks, before: current, isJumpTarget) == nil)
                .accessibilityLabel(Text("Previous edit, command or failure"))
                .accessibilityIdentifier("studio.scrub.prev")
            Button { d.togglePlay() } label: { Image(systemName: playing ? "pause.fill" : "play.fill").contentTransition(.symbolEffect(.replace)) }
                .buttonStyle(ScrubButton())
                .disabled(marks.isEmpty)
                .accessibilityLabel(Text(playing ? "Pause replay" : live ? "Replay the session" : "Resume replay"))
                .accessibilityIdentifier("studio.scrub.play")
            Button { jump(back: false) } label: { Image(systemName: "forward.end.fill") }
                .buttonStyle(ScrubButton())
                .disabled(live || Scrub.next(marks, after: current, isJumpTarget) == nil)
                .accessibilityLabel(Text("Next edit, command or failure"))
                .accessibilityIdentifier("studio.scrub.next")
            Button { d.cycleRate() } label: {
                Text("\(Int(d.rate))×").font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit()).frame(minWidth: 26)
            }
            .buttonStyle(ScrubButton(active: d.rate > 1))
            .accessibilityLabel(Text("Replay speed \(Int(d.rate)) times"))
            .accessibilityIdentifier("studio.scrub.rate")

            track(marks)

            if let t = dragIndex.flatMap({ i in marks.first { $0.id == i } }), !compact {
                Text(t.title).font(.system(size: 11.5)).foregroundStyle(Theme.textDim).lineLimit(1).frame(maxWidth: 200, alignment: .leading)
            } else if d.queued > 0 && live {
                Text("+\(d.queued)").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.purple)
                    .contentTransition(.numericText(value: Double(d.queued)))
            }

            Button { d.goLive() } label: {
                HStack(spacing: 4) {
                    Circle().fill(live ? Theme.red : Theme.textFaint).frame(width: 6, height: 6)
                    Text("LIVE").font(.system(size: 10.5, weight: .bold)).tracking(0.6)
                    if !live && d.missed > 0 { Text("+\(d.missed)").font(.system(size: 10.5, weight: .bold).monospacedDigit()) }
                }
                .foregroundStyle(live ? Theme.red : Theme.text)
                .padding(.horizontal, 8).frame(height: 26)
                .background((live ? Theme.red : Theme.accent).opacity(live ? 0.12 : 0.18), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(live)
            .accessibilityLabel(Text(live ? "Live" : "Back to live"))
            .accessibilityIdentifier("studio.scrub.live")
        }
        .padding(.horizontal, compact ? 8 : 14).frame(height: 44)
        .background(Theme.surface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    var current: Int { live ? d.marks.count : d.position }
    func isJumpTarget(_ k: ScrubMark.Kind) -> Bool { [.edit, .command, .test, .failure].contains(k) }

    func jump(back: Bool) {
        let target = back ? Scrub.previous(d.marks, before: current, isJumpTarget) : Scrub.next(d.marks, after: current, isJumpTarget)
        if let target { Device.tap(); d.seek(to: target, play: playing || live) }
    }

    func track(_ marks: [ScrubMark]) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let n = marks.count
            let head = dragIndex ?? current
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.raised).frame(height: 6)
                Capsule().fill(Theme.accent.opacity(0.35)).frame(width: max(6, Scrub.x(of: head, width: w, count: n)), height: 6)
                Canvas { gc, size in Self.drawMarks(&gc, size: size, marks: marks) }
                    .frame(height: 22)
                Circle().fill(live ? Theme.red : Theme.accent)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Theme.surface, lineWidth: 2))
                    .shadow(color: Theme.shadow, radius: 3, y: 1)
                    .offset(x: Scrub.x(of: head, width: w, count: n) - 6)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in dragIndex = Scrub.index(at: v.location.x, width: w, count: n) }
                .onEnded { v in
                    let i = Scrub.index(at: v.location.x, width: w, count: n)
                    dragIndex = nil
                    guard n > 0 else { return }
                    Device.tap()
                    d.seek(to: i, play: playing)
                })
        }
        .frame(height: 30)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Session timeline"))
        .accessibilityValue(Text(live ? "Live" : "Event \(d.position + 1) of \(marks.count)"))
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: if let i = Scrub.next(marks, after: current, isJumpTarget) { d.seek(to: i, play: false) }
            case .decrement: if let i = Scrub.previous(marks, before: current, isJumpTarget) { d.seek(to: i, play: false) }
            @unknown default: break
            }
        }
        .accessibilityIdentifier("studio.scrub.track")
    }

    static func color(_ k: ScrubMark.Kind) -> Color? {
        switch k {
        case .edit: return Theme.accent
        case .command: return Theme.textFaint
        case .test: return Theme.green
        case .failure: return Theme.red
        case .message: return Theme.purple
        case .image: return Theme.blue
        case .prompt: return Theme.text
        case .done: return Theme.green
        default: return nil
        }
    }

    static func drawMarks(_ gc: inout GraphicsContext, size: CGSize, marks: [ScrubMark]) {
        let n = marks.count
        guard n > 0 else { return }
        let mid = size.height / 2
        for m in marks {
            guard let c = color(m.kind) else { continue }
            let x = Scrub.x(of: m.id, width: size.width, count: n)
            let tall: CGFloat = m.kind == .failure ? 20 : m.kind == .prompt || m.kind == .done ? 16 : m.kind == .edit ? 12 : 8
            let w: CGFloat = m.kind == .failure ? 2.5 : 1.5
            gc.fill(Path(roundedRect: CGRect(x: x - w / 2, y: mid - tall / 2, width: w, height: tall), cornerRadius: w / 2), with: .color(c))
        }
    }
}

struct ScrubButton: ButtonStyle {
    var active = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(!enabled ? Theme.textFaint.opacity(0.5) : active ? Theme.accent : Theme.text)
            .frame(width: 30, height: 30)
            .background(configuration.isPressed ? Theme.hover : active ? Theme.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
    }
}
