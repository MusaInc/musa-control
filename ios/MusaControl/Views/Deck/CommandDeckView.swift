import SwiftUI

/// Command Deck: every agent at once. Each live agent is a tile with a
/// miniature of its stage (the file it's in, the lines it just wrote, its
/// last terminal line, its plan) and a heartbeat of its real event rate.
/// Tiles size themselves by activity and urgency; tapping one grows it into
/// the agent's full studio. Nothing moves unless an event moved it.
struct CommandDeckView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.compactLayout) private var compact
    @State private var store = DeckStore()
    @State private var now = Date()
    @State private var visible = false
    @Namespace private var ns

    var animate: Bool { visible && scenePhase == .active && !reduceMotion }
    var nowMs: Double { now.timeIntervalSince1970 * 1000 }

    var body: some View {
        let entries = DeckEntry.build(agents: app.agents, pulses: store.pulses, now: nowMs)
        let liveIds = entries.filter { !$0.chip }.map(\.id)
        let waiting = entries.filter { $0.aura == .approval }.map(\.id)
        ZStack {
            Group {
                if compact || Device.isPhone {
                    PhoneDeck(entries: entries, ns: ns, animate: animate, reduceMotion: reduceMotion, openStudio: openStudio)
                } else {
                    PadDeck(entries: entries, ns: ns, animate: animate, reduceMotion: reduceMotion, openStudio: openStudio)
                }
            }
            .allowsHitTesting(app.studioAgent == nil)
            .accessibilityHidden(app.studioAgent != nil)

            if let id = app.studioAgent {
                AgentStudioView(agentId: id)
                    .id(id)
                    .background(Theme.bg)
                    .deckHero(id, ns, enabled: !reduceMotion)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .background(Theme.bg)
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .task {
            // The deck's own clock: auras age (working → thinking → resting)
            // without any event, so re-derive them every couple of seconds.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if scenePhase == .active { now = Date() }
            }
        }
        .task(id: liveIds + entries.filter(\.chip).map(\.id)) {
            await store.load(entries.map(\.id), client: app.client)
            store.ingest(Array(app.liveEvents.suffix(200)))
            now = Date()
        }
        .onChange(of: app.eventTick) { _, _ in
            store.ingest(Array(app.liveEvents.suffix(40)))
            now = Date()
        }
        .sensoryFeedback(.warning, trigger: waiting) { old, new in !Set(new).isSubset(of: Set(old)) }
    }

    func openStudio(_ id: String) {
        Device.tap()
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.55, bounce: 0.14)) { app.studioAgent = id }
    }
}

extension View {
    /// Shared-element transition between a deck tile and its studio.
    @ViewBuilder func deckHero(_ id: String, _ ns: Namespace.ID, enabled: Bool) -> some View {
        if enabled { matchedGeometryEffect(id: "deck-\(id)", in: ns) } else { self }
    }
}

// MARK: - iPad

struct PadDeck: View {
    let entries: [DeckEntry]
    let ns: Namespace.ID
    let animate: Bool
    let reduceMotion: Bool
    let openStudio: (String) -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        let byId = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        let energy = DeckEnergy.of(entries)
        VStack(spacing: 0) {
            DeckHeader(entries: entries, energy: energy)
            GeometryReader { geo in
                let items = entries.map { DeckItem(id: $0.id, weight: $0.weight, chip: $0.chip) }
                let placements = DeckLayout.solve(items, in: geo.size)
                ZStack(alignment: .topLeading) {
                    DeckThreads(links: DeckLinks.of(entries, placements), animate: animate)
                    if entries.isEmpty {
                        EmptyNote(icon: "rectangle.3.group", text: "No agents running", detail: "Start a task from the sidebar; it appears here as a live tile the moment it does something.")
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                    ForEach(placements) { p in
                        if let e = byId[p.id], app.studioAgent != p.id {
                            Group {
                                if p.role == .chip {
                                    DeckChip(entry: e, project: app.project(e.agent.project)) { openStudio(e.id) }
                                } else {
                                    DeckTile(entry: e, role: p.role, project: app.project(e.agent.project), animate: animate) { openStudio(e.id) }
                                }
                            }
                            .frame(width: p.rect.width, height: p.rect.height)
                            .deckHero(e.id, ns, enabled: !reduceMotion)
                            .position(x: p.rect.midX, y: p.rect.midY)
                            .zIndex(e.aura == .approval ? 3 : e.aura == .failed ? 2 : 1)
                            .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.scale(scale: 0.85).combined(with: .opacity))
                        }
                    }
                }
                .animation(reduceMotion ? .easeInOut(duration: 0.25) : .spring(duration: 0.7, bounce: 0.16), value: placements)
            }
            .padding(.horizontal, 18).padding(.bottom, 18).padding(.top, 4)
        }
        .background { DeckField(energy: energy, animate: animate) }
    }
}

struct DeckHeader: View {
    let entries: [DeckEntry]
    let energy: Double
    @Environment(\.compactLayout) private var compact

    var body: some View {
        let live = entries.filter { !$0.chip }
        let waiting = live.filter { $0.aura == .approval }.count
        let working = live.filter { $0.aura == .working || $0.aura == .thinking }.count
        let failed = live.filter { $0.aura == .failed }.count
        let rate = live.reduce(0) { $0 + $1.rate }
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Command Deck").font(.system(size: compact ? 20 : 24, weight: .bold)).foregroundStyle(Theme.text)
                HStack(spacing: 10) {
                    HeaderCount(value: live.count, label: "live", color: Theme.textDim)
                    if working > 0 { HeaderCount(value: working, label: "working", color: Theme.blue) }
                    if waiting > 0 { HeaderCount(value: waiting, label: "need you", color: Theme.yellow) }
                    if failed > 0 { HeaderCount(value: failed, label: "failing", color: Theme.red) }
                }
            }
            Spacer(minLength: 8)
            EnergyGauge(energy: energy, rate: rate)
        }
        .padding(.horizontal, compact ? 16 : 22).padding(.top, compact ? 10 : 16).padding(.bottom, 10)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct HeaderCount: View {
    let value: Int
    let label: String
    let color: Color
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(value)").font(.system(size: 12.5, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.text)
                .contentTransition(.numericText(value: Double(value)))
            Text(label).font(.system(size: 12.5)).foregroundStyle(Theme.textDim)
        }
        .animation(.snappy, value: value)
    }
}

/// Total events per minute across every live agent, as a segmented meter.
struct EnergyGauge: View {
    let energy: Double
    let rate: Int
    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(rate)").font(.system(size: 18, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(Theme.text)
                    .contentTransition(.numericText(value: Double(rate)))
                Text("events / min").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.textFaint)
            }
            HStack(alignment: .bottom, spacing: 2.5) {
                ForEach(0..<12, id: \.self) { i in
                    let on = Double(i) < energy * 12 - 0.01
                    RoundedRectangle(cornerRadius: 1.2)
                        .fill(on ? Theme.accent : Theme.lineStrong)
                        .frame(width: 3.5, height: 7 + CGFloat(i) * 1.6)
                }
            }
            .animation(.easeOut(duration: 0.5), value: energy)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(rate) events in the last minute across all agents"))
    }
}

enum DeckEnergy {
    /// 0…1 from the real event rate of live agents (30 events/min = full).
    static func of(_ es: [DeckEntry]) -> Double {
        let r = es.filter { !$0.chip }.reduce(0) { $0 + $1.rate }
        return min(1, Double(r) / 30)
    }
}

/// Faint threads between agents working in the same project.
enum DeckLinks {
    struct Link: Equatable { let a: CGPoint; let b: CGPoint; let lively: Bool }
    static func of(_ es: [DeckEntry], _ ps: [DeckPlacement]) -> [Link] {
        let rect = Dictionary(uniqueKeysWithValues: ps.map { ($0.id, $0.rect) })
        var out: [Link] = []
        let byProject = Dictionary(grouping: es.filter { $0.agent.project != nil && rect[$0.id] != nil }, by: { $0.agent.project! })
        for (_, group) in byProject.sorted(by: { $0.key < $1.key }) where group.count > 1 {
            for i in 0..<(group.count - 1) {
                guard let r1 = rect[group[i].id], let r2 = rect[group[i + 1].id] else { continue }
                out.append(Link(a: CGPoint(x: r1.midX, y: r1.midY), b: CGPoint(x: r2.midX, y: r2.midY),
                                lively: group[i].aura.lively || group[i + 1].aura.lively))
            }
        }
        return out
    }
}

// MARK: - Ambient layer

/// Integrates the field's phase so its speed can follow activity without the
/// pattern jumping when the speed changes. Plain reference, not observed.
final class FieldClock {
    var last: Double?
    var phase: Double = 0
    var energy: Double = 0
    func advance(to t: Double, target: Double) -> (phase: Double, energy: Double) {
        let dt = min(0.1, max(0, t - (last ?? t)))
        last = t
        energy += (target - energy) * min(1, dt * 1.5)
        phase += dt * (0.015 + 0.06 * energy)
        if phase > 10_000 { phase -= 10_000 }
        return (phase, energy)
    }
}

/// The slow generative field behind the deck (a Metal shader). Its energy
/// follows total agent activity; still and shader-free with Reduce Motion
/// or while the app is in the background.
struct DeckField: View {
    let energy: Double
    let animate: Bool
    @State private var clock = FieldClock()

    var body: some View {
        GeometryReader { geo in
            if animate {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: !animate)) { ctx in
                    let s = clock.advance(to: ctx.date.timeIntervalSinceReferenceDate, target: energy)
                    Rectangle().fill(Theme.bg)
                        .colorEffect(ShaderLibrary.deckField(.float2(geo.size), .float(s.phase), .float(s.energy), .color(Theme.field), .color(Theme.fieldCool)))
                }
            } else {
                ZStack {
                    Theme.bg
                    RadialGradient(colors: [Theme.accent.opacity(0.06 + 0.08 * energy), .clear], center: .topLeading,
                                   startRadius: 20, endRadius: max(geo.size.width, geo.size.height) * 0.8)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Faint animated threads linking agents that work in the same project.
struct DeckThreads: View {
    let links: [DeckLinks.Link]
    let animate: Bool

    static func point(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ u: CGFloat) -> CGPoint {
        let v: CGFloat = 1 - u
        let x: CGFloat = v * v * a.x + 2 * v * u * c.x + u * u * b.x
        let y: CGFloat = v * v * a.y + 2 * v * u * c.y + u * u * b.y
        return CGPoint(x: x, y: y)
    }

    static func draw(_ gc: inout GraphicsContext, links: [DeckLinks.Link], t: Double, motes: Bool) {
        for (i, l) in links.enumerated() {
            let a: CGPoint = l.a, b: CGPoint = l.b
            let dx: CGFloat = b.x - a.x, dy: CGFloat = b.y - a.y
            let len: CGFloat = max(1, hypot(dx, dy))
            let sign: CGFloat = i % 2 == 0 ? 1 : -1
            let bend: CGFloat = min(80, len * 0.18) * sign
            let c = CGPoint(x: (a.x + b.x) / 2 - dy / len * bend, y: (a.y + b.y) / 2 + dx / len * bend)
            var p = Path()
            p.move(to: a)
            p.addQuadCurve(to: b, control: c)
            let alpha: Double = l.lively ? 0.34 : 0.16
            let style = StrokeStyle(lineWidth: 1, lineCap: .round, dash: [2, 6], dashPhase: CGFloat(-t * 14))
            gc.stroke(p, with: .color(Theme.accent.opacity(alpha)), style: style)
            guard l.lively && motes else { continue }
            // A mote travelling along the thread.
            let u = CGFloat((t * 0.22 + Double(i) * 0.37).truncatingRemainder(dividingBy: 1))
            let q = point(a, c, b, u)
            gc.fill(Path(ellipseIn: CGRect(x: q.x - 2.5, y: q.y - 2.5, width: 5, height: 5)), with: .color(Theme.accent.opacity(0.7)))
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animate || links.isEmpty)) { ctx in
            let t = animate ? ctx.date.timeIntervalSinceReferenceDate : 0
            Canvas { gc, _ in Self.draw(&gc, links: links, t: t, motes: animate) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Tiles

struct DeckPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.3), value: configuration.isPressed)
    }
}

struct DeckTile: View {
    let entry: DeckEntry
    let role: DeckPlacement.Role
    let project: Project?
    let animate: Bool
    let action: () -> Void

    var a: Agent { entry.agent }
    var p: AgentPulse { entry.pulse }
    var big: Bool { role == .hero }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: role == .compact ? 6 : 10) {
                header
                if role == .compact {
                    compactLine
                    Spacer(minLength: 0)
                } else {
                    if entry.aura == .approval, let ap = a.approval { ApprovalStrip(prompt: ap, big: big) }
                    MiniStage(pulse: p, aura: entry.aura, maxLines: big ? 8 : 4, animate: animate)
                    if p.planTotal > 0 { PlanRail(done: p.planDone, total: p.planTotal, current: p.planCurrent, showText: true) }
                }
                footer
            }
            .padding(role == .compact ? 10 : 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.surface.opacity(0.94), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay { AuraFrame(aura: entry.aura, animate: animate, failTs: p.failTs) }
            .shadow(color: Theme.shadow, radius: entry.aura == .approval ? 22 : 12, y: 6)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(DeckPress())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(entry.accessibilitySummary))
        .accessibilityHint(Text("Opens the live studio"))
        .accessibilityIdentifier("deck.tile.\(a.id)")
    }

    var header: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentAvatar(kind: a.agent, status: a.status, size: big ? 36 : role == .compact ? 24 : 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(a.title).font(.system(size: big ? 17 : role == .compact ? 13.5 : 15, weight: .semibold))
                    .foregroundStyle(Theme.text).lineLimit(role == .compact ? 1 : 2)
                HStack(spacing: 5) {
                    if let project { Text(project.name).foregroundStyle(Theme.accent).fontWeight(.semibold) }
                    Text(a.shortName).foregroundStyle(Theme.textFaint)
                }
                .font(.system(size: 11.5)).lineLimit(1)
            }
            Spacer(minLength: 4)
            AuraPill(aura: entry.aura, small: role == .compact)
        }
    }

    var compactLine: some View {
        let text: String = {
            if entry.aura == .approval, let q = a.approval?.command ?? a.approval?.question { return q }
            if let v = p.verb, let f = p.file { return "\(v.rawValue) \((f as NSString).lastPathComponent)" }
            return p.term ?? p.message ?? a.statusText
        }()
        return Text(text).font(.system(size: 12, design: p.term != nil && p.file == nil ? .monospaced : .default))
            .foregroundStyle(entry.aura == .failed ? Theme.red : Theme.textDim).lineLimit(1).truncationMode(.middle)
    }

    var footer: some View {
        HStack(spacing: 10) {
            Heartbeat(times: p.times, aura: entry.aura, animate: animate)
                .frame(height: big ? 30 : role == .compact ? 16 : 22)
            VStack(alignment: .trailing, spacing: 0) {
                Text("\(entry.rate)/min").font(.system(size: 11.5, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.textDim)
                if role != .compact { Text(Fmt.ago(p.lastTs > 0 ? p.lastTs : a.lastActivity)).font(.system(size: 10.5)).foregroundStyle(Theme.textFaint) }
            }
            .fixedSize()
        }
    }
}

struct AuraPill: View {
    let aura: DeckAura
    var small = false
    var body: some View {
        let c = Theme.aura(aura)
        HStack(spacing: 4) {
            Image(systemName: aura.icon).font(.system(size: small ? 9.5 : 10.5, weight: .bold))
            if !small { Text(aura.label).font(.system(size: 11, weight: .semibold)) }
        }
        .foregroundStyle(c)
        .padding(.horizontal, small ? 5 : 8).padding(.vertical, 3)
        .background(c.opacity(0.14), in: Capsule())
        .fixedSize()
    }
}

/// Border light. Working: a slow comet sweeping the edge. Approval: a warm
/// breathing glow. Failed: red, with a flare when the failure lands.
struct AuraFrame: View {
    let aura: DeckAura
    let animate: Bool
    let failTs: Double
    var radius: CGFloat = 16
    @State private var flare = 0

    var body: some View {
        let c = Theme.aura(aura)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape.stroke(aura == .resting || aura == .done ? Theme.lineStrong : c.opacity(0.45), lineWidth: 1)
            if animate && aura.lively {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: !animate)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    switch aura {
                    case .working:
                        shape.stroke(AngularGradient(colors: [c.opacity(0), c.opacity(0), c.opacity(0.95), c.opacity(0)],
                                                     center: .center, angle: .degrees(t * 70)), lineWidth: 1.6)
                    case .approval:
                        let v = 0.5 + 0.5 * sin(t * 3.2)
                        shape.stroke(c.opacity(0.55 + 0.45 * v), lineWidth: 2)
                            .shadow(color: c.opacity(0.35 + 0.35 * v), radius: 6 + 10 * v)
                    default:
                        shape.stroke(c.opacity(0.8), lineWidth: 1.6)
                    }
                }
            } else if aura == .approval || aura == .failed {
                shape.stroke(c.opacity(0.85), lineWidth: 2)
            }
        }
        .onChange(of: failTs) { _, ts in
            // Only a failure that just happened flares, not one loaded from history.
            if Date().timeIntervalSince1970 * 1000 - ts < 15_000 { flare &+= 1 }
        }
        .keyframeAnimator(initialValue: 0.0, trigger: flare) { view, v in
            view.overlay(shape.fill(Theme.red.opacity(animate ? v * 0.22 : 0)))
        } keyframes: { _ in
            KeyframeTrack {
                LinearKeyframe(1.0, duration: 0.08)
                CubicKeyframe(0.0, duration: 0.9)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The approval question on a tile: what exactly it wants to run.
struct ApprovalStrip: View {
    let prompt: ApprovalPrompt
    let big: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(prompt.question, systemImage: "hand.raised.fill").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.yellow).lineLimit(1)
            if let c = prompt.command {
                Text(c).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text).lineLimit(big ? 3 : 1).truncationMode(.middle)
            }
            Text("Tap to review").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textDim)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Miniature stage: the file tab, the lines the agent wrote there (typed in
/// on arrival), and its last terminal line. Dark like the real stage.
struct MiniStage: View {
    let pulse: AgentPulse
    let aura: DeckAura
    let maxLines: Int
    let animate: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let f = pulse.file {
                let name = (f as NSString).lastPathComponent
                let g = fileGlyph(name, dir: false)
                HStack(spacing: 6) {
                    Image(systemName: g.0).font(.system(size: 10)).foregroundStyle(g.1)
                    Text(name).font(.system(size: 11.5, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.inkText).lineLimit(1).truncationMode(.middle)
                    if let v = pulse.verb { Text(v.rawValue.lowercased()).font(.system(size: 10.5)).foregroundStyle(Theme.inkDim) }
                    Spacer(minLength: 4)
                    if pulse.added > 0 { Text("+\(pulse.added)").foregroundStyle(Theme.green) }
                    if pulse.removed > 0 { Text("−\(pulse.removed)").foregroundStyle(Theme.red) }
                }
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 10).frame(height: 24)
                .background(Theme.inkRaised)
            }
            Group {
                if !pulse.snippet.isEmpty {
                    TypedCode(lines: pulse.snippet, path: pulse.file ?? "", seen: pulse.lineSeen, maxLines: maxLines, animate: animate)
                } else if let m = pulse.message, pulse.file == nil {
                    Text(m).font(.system(size: 12)).foregroundStyle(Theme.inkDim).lineLimit(maxLines)
                } else if pulse.file != nil {
                    Text(pulse.verb == .reading ? "Reading…" : "No text in this change").font(.system(size: 11.5)).foregroundStyle(Theme.inkDim)
                } else {
                    Text("Nothing on screen yet").font(.system(size: 11.5)).foregroundStyle(Theme.inkDim)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            if let t = pulse.term {
                HStack(spacing: 6) {
                    Text(t).font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(termColor).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    if let s = pulse.tests {
                        Text(s).font(.system(size: 10.5, weight: .bold, design: .rounded)).lineLimit(1)
                            .foregroundStyle(pulse.testsOK == false ? Theme.red : Theme.green)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(pulse.testsOK == false ? Theme.red : Theme.green, lineWidth: 1))
                            .layoutPriority(1)
                    }
                }
                .padding(.horizontal, 10).frame(height: 26)
                .background(Theme.inkRaised.opacity(0.6))
                .overlay(alignment: .top) { Rectangle().fill(Theme.inkLine).frame(height: 1) }
                .id(t)
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.ink, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .environment(\.colorScheme, .dark)
        .animation(.easeOut(duration: 0.25), value: pulse.term)
    }

    var termColor: Color {
        switch pulse.termKind {
        case .command: return Color(red: 0.62, green: 0.86, blue: 0.62)
        case .ok: return Theme.green
        case .fail: return Theme.red
        default: return Theme.inkText.opacity(0.8)
        }
    }
}

/// The agent's own lines, typed in when they arrive (once), then still.
struct TypedCode: View {
    let lines: [String]
    let path: String
    let seen: Double
    let maxLines: Int
    let animate: Bool
    @State private var typing = false

    var shown: [String] { Array(lines.prefix(maxLines)) }
    var total: Int { shown.reduce(0) { $0 + $1.count } }
    var duration: Double { min(2.6, max(0.5, Double(total) / 55)) }

    var body: some View {
        let hl = shown.map { SyntaxHighlighter.attributed($0, path: path) }
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !typing)) { ctx in
            let elapsed = ctx.date.timeIntervalSince1970 - seen / 1000
            let n = typing ? Int(Double(total) * min(1, max(0, elapsed / duration))) : total
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(hl.enumerated()), id: \.offset) { i, line in
                    let before = shown[..<i].reduce(0) { $0 + $1.count }
                    let k = max(0, min(shown[i].count, n - before))
                    if n >= before || i == 0 {
                        HStack(spacing: 0) {
                            Text(Self.prefix(line, k)).font(.system(size: 12, design: .monospaced))
                            if typing && k < shown[i].count && n >= before {
                                Rectangle().fill(Theme.accent).frame(width: 2, height: 13)
                            }
                        }
                        .lineLimit(1)
                    }
                }
            }
        }
        .task(id: seen) {
            let age = Date().timeIntervalSince1970 - seen / 1000
            guard animate, age < duration else { typing = false; return }
            typing = true
            try? await Task.sleep(nanoseconds: UInt64(max(0.05, duration - age + 0.1) * 1_000_000_000))
            typing = false
        }
    }

    static func prefix(_ s: AttributedString, _ n: Int) -> AttributedString {
        let count = s.characters.count
        guard n < count else { return s }
        let end = s.characters.index(s.startIndex, offsetBy: max(0, n))
        return AttributedString(s[s.startIndex..<end])
    }
}

/// Plan progress as segments; the current step glows.
struct PlanRail: View {
    let done: Int
    let total: Int
    let current: String?
    var showText = true
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 3) {
                ForEach(0..<min(total, 14), id: \.self) { i in
                    Capsule().fill(i < done ? Theme.green : i == done ? Theme.blue : Theme.lineStrong)
                        .frame(height: 4)
                }
            }
            if showText {
                HStack(spacing: 6) {
                    Text("\(done)/\(total)").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.textDim)
                    if let current { Text(current).font(.system(size: 11.5)).foregroundStyle(Theme.text).lineLimit(1) }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Plan: \(done) of \(total) done\(current.map { ". Now: \($0)" } ?? "")"))
    }
}

/// ECG-style trace: one blip per real event, scrolling left in real time
/// over the last 90 seconds. Flat when nothing has happened.
struct Heartbeat: View {
    let times: [Double]
    let aura: DeckAura
    let animate: Bool
    static let window: Double = 90_000

    var body: some View {
        let nowMs = Date().timeIntervalSince1970 * 1000
        let recent = times.contains { $0 > nowMs - Self.window }
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !(animate && (recent || aura.lively)))) { ctx in
            let now = ctx.date.timeIntervalSince1970 * 1000
            Canvas { gc, size in
                let mid = size.height * 0.62
                let amp = size.height * 0.55
                let xs = times.filter { $0 > now - Self.window && $0 <= now + 2_000 }
                    .map { size.width * CGFloat(1 - (now - $0) / Self.window) }.sorted()
                var p = Path()
                p.move(to: CGPoint(x: 0, y: mid))
                var lastX: CGFloat = -10
                for x in xs where x - 5 > lastX {
                    p.addLine(to: CGPoint(x: x - 5, y: mid))
                    p.addLine(to: CGPoint(x: x - 2.5, y: mid + amp * 0.18))
                    p.addLine(to: CGPoint(x: x, y: mid - amp))
                    p.addLine(to: CGPoint(x: x + 2.5, y: mid + amp * 0.28))
                    p.addLine(to: CGPoint(x: x + 5, y: mid))
                    lastX = x + 5
                }
                p.addLine(to: CGPoint(x: size.width, y: mid))
                let c = Theme.aura(aura)
                gc.stroke(p, with: .linearGradient(Gradient(colors: [c.opacity(0), c.opacity(0.9)]), startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)),
                          style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                if aura.lively {
                    let v = 0.5 + 0.5 * sin(ctx.date.timeIntervalSinceReferenceDate * 4)
                    let r = 2.5 + 1.5 * v
                    gc.fill(Path(ellipseIn: CGRect(x: size.width - r, y: mid - r, width: r * 2, height: r * 2)), with: .color(c))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

struct DeckChip: View {
    let entry: DeckEntry
    let project: Project?
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                AgentAvatar(kind: entry.agent.agent, status: entry.agent.status, size: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.agent.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(project?.name ?? entry.agent.shortName).font(.system(size: 10.5)).foregroundStyle(Theme.textFaint).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: entry.aura.icon).font(.system(size: 10.5)).foregroundStyle(Theme.aura(entry.aura))
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.surface.opacity(0.9), in: Capsule())
            .overlay(Capsule().stroke(Theme.line))
        }
        .buttonStyle(DeckPress())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(entry.agent.agentName): \(entry.agent.title). \(entry.aura.label). Settled."))
        .accessibilityIdentifier("deck.chip.\(entry.agent.id)")
    }
}

// MARK: - iPhone

/// Phone: a swipeable hero card for the most active agents, then a stack of
/// focus cards, then settled chips.
struct PhoneDeck: View {
    let entries: [DeckEntry]
    let ns: Namespace.ID
    let animate: Bool
    let reduceMotion: Bool
    let openStudio: (String) -> Void
    @Environment(AppModel.self) private var app
    @State private var page: String?

    var body: some View {
        let live = entries.filter { !$0.chip }
        let heroes = Array(live.prefix(3))
        let rest = Array(live.dropFirst(3))
        let chips = entries.filter(\.chip)
        GeometryReader { geo in
            ZStack(alignment: .top) {
                DeckField(energy: DeckEnergy.of(entries), animate: animate)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        DeckHeader(entries: entries, energy: DeckEnergy.of(entries))
                        if live.isEmpty {
                            EmptyNote(icon: "rectangle.3.group", text: "No agents running", detail: "Agents appear here the moment they do something.").frame(height: 260)
                        }
                        if !heroes.isEmpty {
                            ScrollView(.horizontal) {
                                LazyHStack(spacing: 12) {
                                    ForEach(heroes) { e in
                                        Group {
                                            if app.studioAgent == e.id { Color.clear } else {
                                                DeckTile(entry: e, role: .hero, project: app.project(e.agent.project), animate: animate) { openStudio(e.id) }
                                                    .deckHero(e.id, ns, enabled: !reduceMotion)
                                            }
                                        }
                                        .frame(width: geo.size.width - 40, height: min(400, max(300, geo.size.height * 0.5)))
                                        .id(e.id)
                                    }
                                }
                                .scrollTargetLayout()
                            }
                            .scrollTargetBehavior(.viewAligned)
                            .scrollPosition(id: $page)
                            .contentMargins(.horizontal, 20, for: .scrollContent)
                            .scrollIndicators(.hidden)
                            if heroes.count > 1 {
                                HStack(spacing: 6) {
                                    ForEach(heroes) { e in
                                        Capsule().fill((page ?? heroes.first?.id) == e.id ? Theme.aura(e.aura) : Theme.lineStrong)
                                            .frame(width: (page ?? heroes.first?.id) == e.id ? 18 : 6, height: 6)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .animation(.snappy, value: page)
                                .accessibilityHidden(true)
                            }
                        }
                        ForEach(rest) { e in
                            Group {
                                if app.studioAgent == e.id { Color.clear } else {
                                    DeckTile(entry: e, role: .compact, project: app.project(e.agent.project), animate: animate) { openStudio(e.id) }
                                        .deckHero(e.id, ns, enabled: !reduceMotion)
                                }
                            }
                            .frame(height: 96)
                            .padding(.horizontal, 20)
                            .transition(.opacity)
                        }
                        if !chips.isEmpty {
                            Text("Settled").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textDim).padding(.horizontal, 20).padding(.top, 4)
                            ForEach(chips) { e in
                                DeckChip(entry: e, project: app.project(e.agent.project)) { openStudio(e.id) }
                                    .frame(height: 44)
                                    .padding(.horizontal, 20)
                            }
                        }
                    }
                    .padding(.bottom, 24)
                    .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.5, bounce: 0.15), value: live.map(\.id))
                }
            }
        }
    }
}
