import SwiftUI
import UIKit

/// iPhone: four clean tabs — Agents, Terminal, Files, Settings. The bar hides
/// while the keyboard is up so the agent composer keeps its room.
struct PhoneShell: View {
    @Environment(AppModel.self) private var app
    @State private var keyboard = false

    var body: some View {
        VStack(spacing: 0) {
            if case .offline(let msg) = app.phase { OfflineBar(message: msg) }
            SectionContent()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.compactLayout, true)
            if !keyboard { PhoneTabBar() }
        }
        .background(Theme.bg)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboard = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboard = false }
    }
}

struct PhoneTabBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let waiting = app.agents.filter { $0.status == "approval" }.count
        HStack(spacing: 0) {
            ForEach(AppSection.allCases) { s in
                item(s, badge: s == .agents ? waiting : 0)
            }
        }
        .padding(.top, 6).padding(.bottom, 2)
        .background(Theme.surface.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    func item(_ section: AppSection, badge: Int) -> some View {
        let selected = app.section == section
        return Button {
            Device.tap()
            if section == .agents && selected { app.focusedAgent = nil }   // re-tap: back to the list
            app.go(section)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: section.icon).font(.system(size: 19, weight: selected ? .semibold : .regular))
                    .frame(height: 24)
                    .overlay(alignment: .topTrailing) {
                        if badge > 0 {
                            Text("\(badge)").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.onAccent)
                                .padding(.horizontal, 5).padding(.vertical, 1).background(Theme.yellow, in: Capsule()).offset(x: 10, y: -4)
                        }
                    }
                Text(section.title).font(.system(size: 10.5, weight: selected ? .semibold : .medium)).lineLimit(1)
            }
            .foregroundStyle(selected ? Theme.accent : Theme.textDim)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(badge > 0 ? "\(section.title), \(badge) waiting" : section.title))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("tab.\(section.rawValue)")
    }
}
