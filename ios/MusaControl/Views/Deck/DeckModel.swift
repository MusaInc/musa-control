import SwiftUI

// The Command Deck's data model. Everything here is a pure function of real
// timeline events and the gateway's agent list, so it can be unit-tested and
// so nothing on a tile is ever invented: a tile shows a line of code only if
// an edit event carried it, a terminal line only if a command printed it.

/// How an agent looks right now. Derived from its status and recent events.
enum DeckAura: String, Equatable, CaseIterable {
    case working    // events in the last few seconds
    case thinking   // running, but quiet for a moment
    case approval   // blocked on you
    case failed     // a command, test or API call just failed and nothing has passed since
    case done       // finished its turn recently
    case resting    // idle for a while, or not running

    var label: String {
        switch self {
        case .working: return "Working"
        case .thinking: return "Thinking"
        case .approval: return "Needs approval"
        case .failed: return "Failed"
        case .done: return "Done"
        case .resting: return "Resting"
        }
    }
    var icon: String {
        switch self {
        case .working: return "bolt.fill"
        case .thinking: return "brain"
        case .approval: return "hand.raised.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .done: return "checkmark.seal.fill"
        case .resting: return "moon.zzz"
        }
    }
    /// Animated states; the others are drawn still.
    var lively: Bool { self == .working || self == .approval || self == .failed }
}

/// The latest real activity of one agent, folded from its events.
struct AgentPulse: Equatable {
    enum Verb: String, Equatable { case editing = "Editing", writing = "Writing", deleting = "Deleting", reading = "Reading" }

    var file: String?
    var verb: Verb?
    var snippet: [String] = []   // lines the agent actually wrote (from the edit's own text)
    var lineSeen: Double = 0     // device time (ms) they arrived, for the typing reveal
    var added = 0
    var removed = 0
    var term: String?            // last terminal line: the command, or its last line of output
    var termKind: TermLine.Kind = .output
    var tests: String?           // pass/fail summary quoted from test output
    var testsOK: Bool?
    var planDone = 0
    var planTotal = 0
    var planCurrent: String?
    var message: String?         // last thing it said
    var lastTitle: String?
    var lastKind: String?
    var lastTs: Double = 0
    var failTs: Double = 0
    var okTs: Double = 0
    var doneTs: Double = 0
    var times: [Double] = []     // recent event times (ms), for the heartbeat
    var events = 0

    static let keep = 96

    mutating func apply(_ e: TimelineEvent, seen: Double = Date().timeIntervalSince1970 * 1000) {
        events += 1
        times.append(e.ts)
        if times.count > Self.keep { times.removeFirst(times.count - Self.keep) }
        guard e.ts >= lastTs else { return }      // late arrival: counts toward the rate only
        lastTs = e.ts
        lastKind = e.kind
        lastTitle = e.title
        let d = e.detail
        switch e.kind {
        case "agent.edit":
            file = d?["path"]?.string ?? file
            let change = d?["change"]?.string
            verb = change == "delete" ? .deleting : (change == "add" || d?["tool"]?.string == "Write") ? .writing : .editing
            let c = Self.change(of: e)
            snippet = c.snippet
            lineSeen = seen
            added = c.added
            removed = c.removed
        case "agent.read":
            file = d?["path"]?.string ?? file
            verb = .reading
            snippet = []
            added = 0; removed = 0
        case "agent.command", "agent.test":
            term = "$ " + StudioDirector.oneLine(d?["command"]?.string ?? e.title, 160)
            termKind = .command
            if d?["output"]?.string != nil || d?["exitCode"]?.number != nil { result(e) }
        case "agent.command_done", "agent.command_failed":
            result(e)
        case "agent.plan":
            let steps = StudioDirector.planSteps(e)
            planTotal = steps.count
            planDone = steps.filter { $0.status == "completed" }.count
            planCurrent = steps.first { $0.status == "in_progress" }?.text
        case "agent.message":
            message = StudioDirector.plainText(d?["text"]?.string ?? e.title, 220)
        case "agent.prompt":
            doneTs = 0
        case "agent.done":
            doneTs = e.ts
        case "agent.error":
            failTs = e.ts
        default:
            break
        }
    }

    private mutating func result(_ e: TimelineEvent) {
        let ok = Self.ok(e)
        let out = e.detail?["output"]?.string ?? ""
        let last = out.components(separatedBy: "\n").map(StudioDirector.stripAnsi)
            .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let code = e.detail?["exitCode"]?.number.map { " (exit \(Int($0)))" } ?? ""
        term = last.map { StudioDirector.oneLine($0.trimmingCharacters(in: .whitespaces), 160) } ?? (ok ? "✓ done\(code)" : "✗ failed\(code)")
        termKind = ok ? .ok : .fail
        if Feed.isTestResult(e) || e.kind == "agent.test" {
            tests = Feed.testSummary(out)
            testsOK = ok
        }
        if ok { okTs = e.ts } else { failTs = e.ts }
    }

    static func ok(_ e: TimelineEvent) -> Bool {
        if e.kind == "agent.command_failed" { return false }
        if let c = e.detail?["exitCode"]?.number { return c == 0 }
        return e.detail?["ok"]?.bool ?? true
    }

    /// What an edit wrote, from the event's own old/new strings or unified
    /// diff: up to `limit` added lines (common indent removed) and the size of
    /// the change. Empty when the event doesn't carry the text.
    static func change(of e: TimelineEvent, limit: Int = 8) -> (snippet: [String], added: Int, removed: Int) {
        let edits: [(String, String)] = (e.detail?["edits"]?.array ?? []).compactMap { v in
            guard let o = v["old"]?.string, let n = v["new"]?.string else { return nil }
            return (o, n)
        }
        var added = 0, removed = 0
        var lines: [String] = []
        if !edits.isEmpty {
            for (o, n) in edits {
                let op = EditScripts.trimmed(EditOp(line: 0, remove: o.isEmpty ? [] : EditScripts.lines(o), insert: n.isEmpty ? [] : EditScripts.lines(n)))
                added += op.insert.count
                removed += op.remove.count
                if lines.isEmpty { lines = op.insert }
            }
        } else if let raw = e.detail?["diff"]?.string, !raw.isEmpty {
            let text = raw.hasPrefix("---") || raw.hasPrefix("diff ") ? raw : "--- a/file\n+++ b/file\n" + raw
            let files = DiffParser.parse(text)
            added = files.reduce(0) { $0 + $1.added }
            removed = files.reduce(0) { $0 + $1.removed }
            // The first run of added lines.
            for l in files.flatMap(\.lines) {
                if l.kind == .added { lines.append(EditScripts.clean(l.text)) } else if !lines.isEmpty { break }
            }
        }
        return (snippet(lines, limit: limit), added, removed)
    }

    /// Drops leading/trailing blank lines and the indent every line shares.
    static func snippet(_ lines: [String], limit: Int) -> [String] {
        func blank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespaces).isEmpty }
        var ls = Array(lines.drop(while: blank))
        while let l = ls.last, blank(l) { ls.removeLast() }
        ls = Array(ls.prefix(limit))
        let indent = ls.filter { !blank($0) }.map { $0.prefix(while: { $0 == " " }).count }.min() ?? 0
        return ls.map { blank($0) ? "" : String($0.dropFirst(indent)) }
    }

    /// Events in the last `window` ms.
    func rate(now: Double, window: Double = 60_000) -> Int { times.reduce(0) { $0 + ($1 > now - window && $1 <= now + 5_000 ? 1 : 0) } }

    static func aura(status: String, pulse p: AgentPulse?, now: Double) -> DeckAura {
        switch status {
        case "approval": return .approval
        case "working":
            if let p, p.failTs > p.okTs, now - p.failTs < 180_000 { return .failed }
            if let p, now - p.lastTs < 25_000 { return .working }
            return .thinking
        case "idle":
            if let p, p.doneTs > 0, now - p.doneTs < 15 * 60_000 { return .done }
            return .resting
        default:
            if let p, p.doneTs > 0, p.doneTs >= p.failTs { return .done }
            return .resting
        }
    }
}

/// One agent on the deck.
struct DeckEntry: Identifiable, Equatable {
    let agent: Agent
    let pulse: AgentPulse
    let aura: DeckAura
    let rate: Int          // events in the last minute
    let chip: Bool         // settled: shown as a chip, not a tile
    var id: String { agent.id }

    /// Size on the deck. Quantised so tiles don't jitter with every event.
    var weight: Double {
        switch aura {
        case .approval: return 3.2
        case .failed: return 2.2
        case .working: return 1.3 + 0.35 * Double(min(3, rate / 4))
        case .thinking: return 1.0
        case .done: return 0.6
        case .resting: return 0.5
        }
    }
    /// Ordering: anything that needs you first, then by activity.
    var rank: Int {
        switch aura { case .approval: return 0; case .failed: return 1; case .working: return 2; case .thinking: return 3; case .done: return 4; case .resting: return 5 }
    }

    static func build(agents: [Agent], pulses: [String: AgentPulse], now: Double, recentChips: Double = 12 * 3_600_000) -> [DeckEntry] {
        var out: [DeckEntry] = []
        for a in agents {
            let live = a.isLive
            guard live || now - a.lastActivity < recentChips else { continue }
            let p = pulses[a.id] ?? AgentPulse()
            let aura = AgentPulse.aura(status: a.status, pulse: pulses[a.id], now: now)
            out.append(DeckEntry(agent: a, pulse: p, aura: aura, rate: p.rate(now: now), chip: !live))
        }
        return sorted(out)
    }

    static func sorted(_ es: [DeckEntry]) -> [DeckEntry] {
        es.sorted { a, b in
            if a.chip != b.chip { return !a.chip }
            if a.rank != b.rank { return a.rank < b.rank }
            if a.weight != b.weight { return a.weight > b.weight }
            if a.agent.lastActivity != b.agent.lastActivity { return a.agent.lastActivity > b.agent.lastActivity }
            return a.id < b.id
        }
    }

    var accessibilitySummary: String {
        var parts = ["\(agent.agentName): \(agent.title)", aura.label]
        if let v = pulse.verb, let f = pulse.file { parts.append("\(v.rawValue) \((f as NSString).lastPathComponent)") }
        if let t = pulse.tests { parts.append("Tests: \(t)") }
        if pulse.planTotal > 0 { parts.append("Plan \(pulse.planDone) of \(pulse.planTotal)") }
        parts.append(rate == 1 ? "1 event in the last minute" : "\(rate) events in the last minute")
        return parts.joined(separator: ". ")
    }
}

// MARK: - Generative layout

struct DeckItem: Equatable { let id: String; let weight: Double; let chip: Bool }

struct DeckPlacement: Identifiable, Equatable {
    enum Role: Equatable { case hero, tile, compact, chip }
    let id: String
    let rect: CGRect
    let role: Role
}

/// Tiles share the space in proportion to their weight (a squarified
/// treemap, so they stay close to square), heaviest first at the top left.
/// Settled agents become a row of chips along the bottom.
enum DeckLayout {
    static let maxTiles = 9

    static func solve(_ items: [DeckItem], in size: CGSize, gap: CGFloat = 12, chipHeight: CGFloat = 40, chipWidth: CGFloat = 230) -> [DeckPlacement] {
        guard size.width > 40, size.height > 40 else { return [] }
        var tiles = items.filter { !$0.chip }
        var chips = items.filter { $0.chip }
        if tiles.count > maxTiles {
            chips = Array(tiles[maxTiles...]) + chips
            tiles = Array(tiles[..<maxTiles])
        }
        var out: [DeckPlacement] = []
        var tileArea = CGRect(origin: .zero, size: size)
        if !chips.isEmpty {
            let y = tiles.isEmpty ? 0 : size.height - chipHeight
            if !tiles.isEmpty { tileArea.size.height = max(0, y - gap) }
            let w = max(150, min(chipWidth, (size.width - gap * CGFloat(chips.count - 1)) / CGFloat(chips.count)))
            var x: CGFloat = 0
            for c in chips {
                guard x + w <= size.width + 0.5 else { break }
                out.append(DeckPlacement(id: c.id, rect: CGRect(x: x, y: y, width: w, height: chipHeight), role: .chip))
                x += w + gap
            }
        }
        guard !tiles.isEmpty else { return out }
        let ordered = tiles.enumerated().sorted { a, b in
            a.element.weight != b.element.weight ? a.element.weight > b.element.weight : a.offset < b.offset
        }.map(\.element)
        let rects = squarify(ordered.map { max(0.05, $0.weight) }, in: tileArea)
        let areas = rects.map { $0.width * $0.height }
        let heroArea = areas.max() ?? 0
        let second = areas.sorted(by: >).dropFirst().first ?? 0
        for (i, t) in ordered.enumerated() {
            let r = inset(rects[i], gap: gap, in: tileArea)
            let role: DeckPlacement.Role
            if min(r.width, r.height) < 170 || r.width * r.height < 52_000 { role = .compact }
            else if ordered.count >= 2, areas[i] == heroArea, heroArea > second * 1.35 { role = .hero }
            else { role = .tile }
            out.append(DeckPlacement(id: t.id, rect: r, role: role))
        }
        return out
    }

    /// Half a gap on every inner edge; outer edges stay flush with the area.
    static func inset(_ r: CGRect, gap: CGFloat, in area: CGRect) -> CGRect {
        let h = gap / 2, eps: CGFloat = 0.5
        let l = r.minX > area.minX + eps ? h : 0, t = r.minY > area.minY + eps ? h : 0
        let rr = r.maxX < area.maxX - eps ? h : 0, b = r.maxY < area.maxY - eps ? h : 0
        return CGRect(x: r.minX + l, y: r.minY + t, width: max(0, r.width - l - rr), height: max(0, r.height - t - b))
    }

    /// Squarified treemap (Bruls, Huizing, van Wijk). `weights` should be in
    /// descending order; the result is in the same order.
    static func squarify(_ weights: [Double], in rect: CGRect) -> [CGRect] {
        guard !weights.isEmpty else { return [] }
        let total = weights.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return weights.map { _ in CGRect(origin: rect.origin, size: .zero) } }
        let scale = Double(rect.width * rect.height) / total
        let areas = weights.map { $0 * scale }
        var out: [CGRect] = []
        var r = rect
        var i = 0
        while i < areas.count {
            let side = Double(min(r.width, r.height))
            var row = [areas[i]]
            var j = i + 1
            while j < areas.count {
                let next = row + [areas[j]]
                if worst(next, side) <= worst(row, side) { row = next; j += 1 } else { break }
            }
            let sum = row.reduce(0, +)
            let thick = CGFloat(side > 0 ? sum / side : 0)
            if j == areas.count {
                // Last row: fill whatever is left exactly (no float drift).
                if r.width >= r.height {
                    var y = r.minY
                    for (k, a) in row.enumerated() {
                        let h = k == row.count - 1 ? r.maxY - y : CGFloat(a / sum) * r.height
                        out.append(CGRect(x: r.minX, y: y, width: r.width, height: h)); y += h
                    }
                } else {
                    var x = r.minX
                    for (k, a) in row.enumerated() {
                        let w = k == row.count - 1 ? r.maxX - x : CGFloat(a / sum) * r.width
                        out.append(CGRect(x: x, y: r.minY, width: w, height: r.height)); x += w
                    }
                }
            } else if r.width >= r.height {
                var y = r.minY
                for a in row { let h = thick > 0 ? CGFloat(a) / thick : 0; out.append(CGRect(x: r.minX, y: y, width: thick, height: h)); y += h }
                r = CGRect(x: r.minX + thick, y: r.minY, width: max(0, r.width - thick), height: r.height)
            } else {
                var x = r.minX
                for a in row { let w = thick > 0 ? CGFloat(a) / thick : 0; out.append(CGRect(x: x, y: r.minY, width: w, height: thick)); x += w }
                r = CGRect(x: r.minX, y: r.minY + thick, width: r.width, height: max(0, r.height - thick))
            }
            i = j
        }
        return out
    }

    static func worst(_ row: [Double], _ side: Double) -> Double {
        let s = row.reduce(0, +)
        guard s > 0, side > 0, let mx = row.max(), let mn = row.min(), mn > 0 else { return .infinity }
        return max(side * side * mx / (s * s), (s * s) / (side * side * mn))
    }
}

// MARK: - Store

/// Folds every agent's events into pulses: a short history per agent on
/// first sight, then the live stream.
@MainActor
@Observable
final class DeckStore {
    private(set) var pulses: [String: AgentPulse] = [:]
    @ObservationIgnored private var seen = Set<String>()
    @ObservationIgnored private var loaded = Set<String>()

    func load(_ ids: [String], client: GatewayClient) async {
        let todo = ids.filter { !loaded.contains($0) }
        guard !todo.isEmpty else { return }
        loaded.formUnion(todo)
        let results: [(String, [TimelineEvent])] = await withTaskGroup(of: (String, [TimelineEvent]).self) { g in
            for id in todo {
                g.addTask {
                    let evs = (try? await client.get("/api/agents/\(id.pathSegment)/timeline", ["limit": "80"], as: [TimelineEvent].self)) ?? []
                    return (id, evs)
                }
            }
            var out: [(String, [TimelineEvent])] = []
            for await r in g { out.append(r) }
            return out
        }
        for (id, evs) in results { ingest(evs.filter { $0.session == id }) }
    }

    func ingest(_ evs: [TimelineEvent]) {
        let fresh = evs.filter { $0.session != nil && seen.insert($0.stableId).inserted }.sorted { $0.ts < $1.ts }
        guard !fresh.isEmpty else { return }
        var next = pulses
        let now = Date().timeIntervalSince1970 * 1000
        for e in fresh { next[e.session!, default: AgentPulse()].apply(e, seen: now) }
        pulses = next
    }
}
