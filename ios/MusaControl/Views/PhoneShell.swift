import SwiftUI
import UIKit

/// iPhone: the same workspace, one panel at a time. Tabs: Workspace (the
/// panels), Agents, Desktop and More (files, computers, settings). The bar
/// hides while the keyboard is up so the composer keeps its room. Remote
/// Desktop stays connected whichever tab is showing.
struct PhoneShell: View {
    @Environment(AppModel.self) private var app
    @State private var keyboard = false

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                if case .offline(let msg) = app.phase { OfflineBar(message: msg) }
                Group {
                    switch app.phoneTab {
                    case .workspace:
                        VStack(spacing: 0) {
                            HStack { ProjectMenu(); Spacer(); AccountMenu() }.padding(.horizontal, 6).frame(height: 40).background(Theme.surface)
                            PanelArea(size: CGSize(width: geo.size.width, height: geo.size.height - 120))
                        }
                    case .agents: AgentsView()
                    case .desktop:
                        if app.desktop.active { DesktopPane(chrome: .compact) }
                        else {
                            VStack(spacing: 12) {
                                EmptyNote(icon: "display", text: "Remote Desktop", detail: "Watch or control the browser and app displays on this computer. The connection stays up while you use the other tabs.")
                                Button { app.desktop.open(client: app.client, machine: app.activeMachine?.id, presentation: .split) } label: { Label("Connect", systemImage: "play.fill") }
                                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    case .more: PhoneMore()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.compactLayout, true)
                if !keyboard { PhoneTabBar() }
            }
            .background(Theme.bg)
            // Keep the desktop alive (and visible as a thumbnail) on other tabs.
            .overlay { if app.desktop.active && app.phoneTab != .desktop { PhoneDesktopThumb(size: geo.size) } }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboard = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboard = false }
    }
}

struct PhoneDesktopThumb: View {
    let size: CGSize
    @Environment(AppModel.self) private var app
    var body: some View {
        let w: CGFloat = 150, h: CGFloat = 94
        DesktopHost(store: app.desktop).allowsHitTesting(false)
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.lineStrong))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            .onTapGesture { app.phoneTab = .desktop }
            .position(x: size.width - w / 2 - 10, y: size.height - h / 2 - 70)
            .accessibilityLabel("Remote Desktop thumbnail")
    }
}

struct PhoneMore: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        List {
            Section("Project") {
                Button { app.phoneTab = .workspace; app.workspace.reveal(.editor) } label: { Label("Editor", systemImage: "chevron.left.forwardslash.chevron.right") }
                NavigationLink { FilesSectionView() } label: { Label("Files", systemImage: "folder") }
                NavigationLink { GitBuildsView() } label: { Label("Source Control & Builds", systemImage: "arrow.triangle.branch") }
                Button { app.phoneTab = .workspace; app.workspace.reveal(.visualiser) } label: { Label("Visualiser", systemImage: "chart.xyaxis.line") }
            }
            Section("Computer") {
                ForEach(app.machines) { m in
                    Button { Task { await app.activate(m) } } label: { Label(m.name, systemImage: m.id == app.activeMachine?.id ? "checkmark.circle.fill" : m.symbol) }
                }
                Button { app.sheet = .machines } label: { Label("Machines & AI accounts", systemImage: "desktopcomputer") }
                Button { app.sheet = .settings } label: { Label("Settings", systemImage: "gearshape") }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .wrapInNavigation()
    }
}

extension View {
    func wrapInNavigation() -> some View { NavigationStack { self.toolbar(.hidden, for: .navigationBar) } }
}

struct PhoneTabBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let waiting = app.agents.filter { $0.status == "approval" }.count
        HStack(spacing: 0) {
            item(.workspace, "Workspace", "rectangle.split.1x2", badge: 0)
            item(.agents, "Agents", "sparkles", badge: waiting)
            item(.desktop, "Desktop", app.desktop.active ? "display.2" : "display", badge: 0)
            item(.more, "More", "ellipsis.circle", badge: 0)
        }
        .padding(.top, 6).padding(.bottom, 2)
        .background(Theme.surface.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    func item(_ tab: PhoneTab, _ title: String, _ icon: String, badge: Int) -> some View {
        let selected = app.phoneTab == tab
        return Button {
            Device.tap()
            if tab == .agents && selected { app.focusedAgent = nil }   // re-tap: back to the list
            app.phoneTab = tab
        } label: {
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
        .accessibilityIdentifier("tab.\(tab.rawValue)")
    }
}
