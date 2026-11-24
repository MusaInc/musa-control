import SwiftUI

/// App shell. iPad: the unified workspace. iPhone: the same workspace one
/// panel at a time, with tabs. Machines & AI and Settings open as sheets
/// over either, so nothing ever navigates away from running work (and the
/// Remote Desktop, which lives above the workspace, stays connected).
struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var quickOpen = false

    var body: some View {
        @Bindable var app = app
        Group {
            if app.phase == .unpaired {
                WelcomeView()
            } else if Device.isPhone {
                PhoneShell()
            } else {
                WorkspaceShell()
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .overlay(alignment: .top) { if let b = app.banner { EventBanner(event: b).transition(.move(edge: .top).combined(with: .opacity)) } }
        .animation(.spring(duration: 0.35), value: app.banner?.stableId)
        .sheet(item: $app.sheet) { s in SheetHost(sheet: s) }
        .sheet(isPresented: $app.showLauncher) { AgentLauncher(initialProject: app.launcherProject) }
        .sheet(isPresented: $app.showSwitcher) { QuickSwitcher() }
        .sheet(isPresented: $app.showQuickOpen) { QuickOpenSheet() }
    }
}

/// Machines & AI and Settings, as sheets with a Done button.
struct SheetHost: View {
    let sheet: AppSheet
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(sheet == .machines ? "Machines & AI" : "Settings").font(Theme.title)
                Spacer()
                Button("Done") { dismiss() }.font(Theme.label).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16).frame(height: 48).background(Theme.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
            Group {
                switch sheet {
                case .machines: MachinesView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.bg)
        .frame(minWidth: Device.isPhone ? nil : 640, minHeight: Device.isPhone ? nil : 620)
    }
}

/// ⌘P: find a file in the current project and open it in the editor.
struct QuickOpenSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Open file").font(Theme.title)
                Spacer()
                Button("Done") { dismiss() }.font(Theme.label)
            }
            .padding(.horizontal, 16).frame(height: 48)
            if let p = app.workspace.projectId ?? app.projects.first?.id {
                FileBrowser(projectId: p, onOpen: { app.workspace.reveal(.editor); dismiss() })
            } else { EmptyNote(icon: "folder", text: "Choose a project first") }
        }
        .frame(minWidth: Device.isPhone ? nil : 560, minHeight: Device.isPhone ? nil : 560)
        .background(Theme.surface)
    }
}

struct ConnectionDot: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let info: (status: String, label: String) = {
            switch (app.phase, app.streamState) {
            case (.ready, .live): return ("idle", "Live")
            case (.ready, .retrying), (.connecting, _): return ("approval", "Reconnecting")
            case (.offline, _): return ("failed", "Offline")
            default: return ("other", "Connecting")
            }
        }()
        StatusDot(status: info.status, size: 7).help(info.label).accessibilityLabel(Text(info.label))
    }
}

struct OfflineBar: View {
    @Environment(AppModel.self) private var app
    let message: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
            Text("Can't reach the gateway — \(message). Agents keep running on the server; retrying automatically.").lineLimit(2)
            Spacer()
            Button("Retry") { Task { await app.connect() } }.font(Theme.label)
        }
        .font(Theme.caption).foregroundStyle(Theme.text)
        .padding(.horizontal, 14).frame(minHeight: 34).background(Theme.red.opacity(0.14))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

struct EventBanner: View {
    @Environment(AppModel.self) private var app
    let event: TimelineEvent
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: event.icon).foregroundStyle(Theme.status(event.tint))
            Text(event.title).font(Theme.label).lineLimit(2)
            Spacer()
            if event.session != nil { Button("Open") { if let s = event.session { app.openAgent(s) }; app.banner = nil }.font(Theme.label) }
            IconButton(systemName: "xmark", help: "Dismiss") { app.banner = nil }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.lineStrong))
        .frame(maxWidth: 560).padding(.top, 10)
        .task(id: event.stableId) { try? await Task.sleep(nanoseconds: 6_000_000_000); if app.banner?.stableId == event.stableId { app.banner = nil } }
    }
}

