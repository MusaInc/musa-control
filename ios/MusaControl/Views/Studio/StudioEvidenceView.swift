import SwiftUI

/// Native layout keeps evidence legible through rapid events and rotation.
/// No absolute-positioned windows or replay transitions in the live desk.
struct StudioEvidenceView: View {
    let d: StudioDirector
    let agent: Agent?
    @State private var picked: PaneKind?

    var available: [PaneKind] {
        var panes: [PaneKind] = []
        if d.openPath != nil { panes.append(.editor) }
        if !d.term.isEmpty { panes.append(.terminal) }
        if d.tests != nil { panes.append(.tests) }
        if d.diff != nil { panes.append(.diff) }
        if !d.plan.isEmpty { panes.append(.plan) }
        if !d.runs.isEmpty { panes.append(.runs) }
        if !d.photos.isEmpty { panes.append(.lightbox) }
        return panes
    }

    var primary: PaneKind {
        if let picked, available.contains(picked) { return picked }
        let preferred: PaneKind
        switch d.currentEvent?.kind {
        case "agent.read", "agent.edit": preferred = .editor
        case "agent.test": preferred = .tests
        case "agent.command", "agent.command_done", "agent.command_failed": preferred = .terminal
        case "agent.image": preferred = .lightbox
        case "agent.plan": preferred = .plan
        default: preferred = d.openPath != nil ? .editor : .terminal
        }
        return available.contains(preferred) ? preferred : available.first ?? .editor
    }

    var secondary: PaneKind? {
        let order: [PaneKind] = primary == .editor ? [.diff, .tests, .terminal, .plan, .runs] : [.editor, .tests, .terminal, .plan, .runs]
        return order.first { $0 != primary && available.contains($0) }
    }

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geo in
                if let secondary {
                    if geo.size.width >= 900 {
                        HStack(spacing: 12) {
                            pane(primary).frame(width: (geo.size.width - 12) * 0.64)
                            pane(secondary)
                        }
                    } else {
                        VStack(spacing: 12) {
                            pane(primary).frame(height: max(100, (geo.size.height - 12) * 0.62))
                            pane(secondary)
                        }
                    }
                } else {
                    pane(primary)
                }
            }
            if available.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(available) { kind in
                            Button { picked = kind; d.userTouched() } label: {
                                Label(kind.title, systemImage: kind.icon)
                                    .font(Theme.label).fixedSize()
                                    .padding(.horizontal, 12).padding(.vertical, 9)
                                    .foregroundStyle(primary == kind ? Theme.onAccent : Theme.textDim)
                                    .background(primary == kind ? Theme.accent : Theme.surface, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("studio.evidence.\(kind.rawValue)")
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(12).background(Theme.bg)
        .coordinateSpace(name: "stage")
        .onChange(of: d.currentEvent?.stableId) { _, _ in picked = nil }
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
    }

    @ViewBuilder func pane(_ kind: PaneKind) -> some View {
        Group {
            switch kind {
            case .editor: EditorWindow(d: d)
            case .terminal: TerminalWindow(d: d)
            case .tests: TestsPane(run: d.tests)
            case .diff: DiffPane(split: d.diff)
            case .plan: PlanPane(steps: d.plan)
            case .runs: RunsPane(runs: d.runs)
            case .lightbox: LightboxPane(photos: d.photos)
            default: EditorWindow(d: d)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .studioRegion(kind.region, d)
        .accessibilityIdentifier("studio.evidence-pane.\(kind.rawValue)")
    }
}
