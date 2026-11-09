import SwiftUI
import UIKit

/// iPhone shell: the section fills the screen and a bottom tab bar holds the
/// four sections used most on a phone. "More" opens the full sidebar (every
/// section, active agents, New agent task) over the content. The bar hides
/// while the keyboard is up so the composer keeps its room.
struct PhoneShell: View {
    @Environment(AppModel.self) private var app
    @State private var keyboard = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                VStack(spacing: 0) {
                    if case .offline(let msg) = app.phase { OfflineBar(message: msg) }
                    SectionDetail()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .environment(\.compactLayout, true)
                    if !keyboard { PhoneTabBar() }
                }
                .background(Theme.bg)
                if app.sidebarOverlay { SidebarOverlay(width: geo.size.width) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboard = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboard = false }
    }
}

struct PhoneTabBar: View {
    @Environment(AppModel.self) private var app
    static let tabs: [AppSection] = [.home, .deck, .agents, .terminal]

    var body: some View {
        let waiting = app.agents.filter { $0.status == "approval" }.count
        let onTab = (app.studioAgent == nil || app.section == .deck) && Self.tabs.contains(app.section)
        HStack(spacing: 0) {
            ForEach(Self.tabs) { s in
                item(title: s == .deck ? "Deck" : s.title, icon: s.icon, selected: onTab && app.section == s, badge: s == .agents ? waiting : 0, id: "tab.\(s.rawValue)") {
                    if app.section == s && app.studioAgent == nil && s == .agents { app.focusedAgent = nil }   // re-tap: back to the list
                    app.go(s)
                }
            }
            item(title: "More", icon: "ellipsis.circle", selected: !onTab, badge: 0, id: "tab.more") {
                withAnimation(.snappy(duration: 0.22)) { app.sidebarOverlay = true }
            }
        }
        .padding(.top, 6).padding(.bottom, 2)
        .background(Theme.surface.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    func item(title: String, icon: String, selected: Bool, badge: Int, id: String, action: @escaping () -> Void) -> some View {
        Button { Device.tap(); action() } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 19, weight: selected ? .semibold : .regular))
                    .frame(height: 24)
                    .overlay(alignment: .topTrailing) {
                        if badge > 0 {
                            Text("\(badge)").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.onAccent)
                                .padding(.horizontal, 5).padding(.vertical, 1).background(Theme.yellow, in: Capsule()).offset(x: 10, y: -4)
                        }
                    }
                Text(title).font(.system(size: 10.5, weight: selected ? .semibold : .medium)).lineLimit(1)
            }
            .foregroundStyle(selected ? Theme.accent : Theme.textDim)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(badge > 0 ? "\(title), \(badge) waiting" : title))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
    }
}
