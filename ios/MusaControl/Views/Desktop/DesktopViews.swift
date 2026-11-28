import SwiftUI
import UIKit

/// The desktop with its controls. Used by every layout (split, floating,
/// full screen); `chrome` trims the toolbar for small windows.
struct DesktopPane: View {
    enum Chrome { case full, compact, minimal }
    var chrome: Chrome = .full
    var onMove: ((CGSize, Bool) -> Void)? = nil      // floating window drag (translation, ended)
    @Environment(AppModel.self) private var app
    @Environment(DesktopStore.self) private var desk
    @State private var confirmControl = false
    @State private var controlError: String?

    var body: some View {
        VStack(spacing: 0) {
            if chrome != .minimal { toolbar }
            ZStack(alignment: .bottomLeading) {
                DesktopHost(store: desk)
                    .accessibilityIdentifier("desktop.screen")
                if !desk.connected { connecting }
                if chrome == .full { stats }
            }
            if desk.showKeys && desk.control && chrome != .minimal { DesktopKeyBar() }
        }
        .background(Color(Theme.terminalBg))
        .confirmationDialog("Control display :\(desk.display)?", isPresented: $confirmControl, titleVisibility: .visible) {
            Button("Take control") {
                Task {
                    do { try await app.enableDesktopControl() }
                    catch { controlError = error.localizedDescription }
                }
            }
        } message: {
            Text(desk.currentDisplay?.native == true
                 ? "This desktop is shared with the Live Work agents. Your clicks and keys go to the same browser they use."
                 : "Your input goes straight to the program drawing on this display.")
        }
        .alert("Desktop control", isPresented: Binding(get: { controlError != nil }, set: { if !$0 { controlError = nil } })) {
            Button("OK") { controlError = nil }
        } message: { Text(controlError ?? "") }
    }

    var connecting: some View {
        VStack(spacing: 8) {
            ProgressView().tint(.white)
            Text(desk.status).font(Theme.caption).foregroundStyle(.white.opacity(0.75))
            Button("Reconnect") { desk.reconnect() }.font(Theme.label).buttonStyle(.bordered).tint(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(Theme.terminalBg).opacity(0.6))
        .allowsHitTesting(true)
    }

    var stats: some View {
        HStack(spacing: 6) {
            StatusDot(status: desk.connected ? "idle" : "approval", size: 6)
            Text(desk.connected ? (desk.control ? "Controlling" : "Watching") : desk.status)
            if let rtt = desk.rtt, desk.connected { Text("\(rtt) ms") }
            if let s = desk.size { Text("\(Int(s.width))×\(Int(s.height))") }
            if desk.control && desk.hasFocus { Label("Keyboard", systemImage: "keyboard").labelStyle(.iconOnly) }
        }
        .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 7).padding(.vertical, 3).background(.black.opacity(0.5), in: Capsule()).padding(6)
        .allowsHitTesting(false)
    }

    var toolbar: some View {
        HStack(spacing: 2) {
            if let onMove {
                Image(systemName: "line.3.horizontal").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textFaint)
                    .frame(width: 26, height: 30).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                        .onChanged { onMove($0.translation, false) }.onEnded { onMove($0.translation, true) })
                    .accessibilityLabel("Move window")
            }
            Menu {
                ForEach(desk.displays) { d in
                    Button { desk.switchDisplay(d.display) } label: {
                        Label("\(d.label)\(d.width.map { " · \($0)×\(d.height ?? 0)" } ?? "")", systemImage: d.display == desk.display ? "checkmark" : "display")
                    }
                }
                Button { Task { await desk.refreshDisplays() } } label: { Label("Refresh displays", systemImage: "arrow.clockwise") }
            } label: {
                HStack(spacing: 4) {
                    StatusDot(status: desk.connected ? "idle" : "approval", size: 6)
                    Text(desk.currentDisplay?.label ?? "Display :\(desk.display)").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).foregroundStyle(Theme.textFaint)
                }.padding(.horizontal, 6).frame(height: 28)
            }
            .accessibilityIdentifier("desktop.display")
            modeToggle
            Spacer(minLength: 4)
            if chrome == .full && desk.control { inputButtons }
            zoomMenu
            if !Device.isPhone { layoutButtons }
            IconButton(systemName: "xmark", help: "Close Remote Desktop (⌃⌘D)") { desk.close() }
                .accessibilityIdentifier("desktop.close")
        }
        .padding(.horizontal, 4).frame(height: 34)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .foregroundStyle(Theme.textDim)
    }

    var modeToggle: some View {
        Button {
            if desk.control { desk.setControl(false) } else { confirmControl = true }
        } label: {
            Label(desk.control ? "Control" : "Watch", systemImage: desk.control ? "cursorarrow.click.2" : "eye")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 8).frame(height: 24)
                .background(desk.control ? Theme.accent.opacity(0.18) : Theme.hover, in: Capsule())
                .foregroundStyle(desk.control ? Theme.accent : Theme.textDim)
        }
        .buttonStyle(.plain)
        .help(desk.control ? "Controlling — tap to switch back to view-only" : "View-only — tap to take control")
        .accessibilityIdentifier("desktop.mode")
    }

    @ViewBuilder var inputButtons: some View {
        IconButton(systemName: desk.showKeys ? "keyboard.fill" : "keyboard", help: "Keys bar (Esc, Tab, arrows, modifiers, typing)", tint: desk.showKeys ? Theme.accent : Theme.textDim) {
            desk.showKeys.toggle(); if desk.showKeys { desk.focusKeyboard() }
        }
        Menu {
            Button { desk.click("right") } label: { Label("Right-click", systemImage: "cursorarrow.rays") }
            Button { desk.click("middle") } label: { Label("Middle-click", systemImage: "circle.circle") }
            Divider()
            Button { desk.scroll(-5) } label: { Label("Scroll up", systemImage: "arrow.up") }
            Button { desk.scroll(5) } label: { Label("Scroll down", systemImage: "arrow.down") }
            Divider()
            Button { desk.pasteFromDevice() } label: { Label("Paste iPad clipboard", systemImage: "doc.on.clipboard") }
            Button { desk.combo([0xffe3, 0xffe9, 0xffff]) } label: { Label("Ctrl+Alt+Delete", systemImage: "power") }
            Toggle("⌘ shortcuts act as Ctrl", isOn: Binding(get: { desk.cmdAsCtrl }, set: { desk.cmdAsCtrl = $0 }))
        } label: { Image(systemName: "computermouse").font(.system(size: 14, weight: .medium)).frame(width: 32, height: 32) }
        .help("Mouse, scrolling and clipboard")
    }

    var zoomMenu: some View {
        Menu {
            Picker("Zoom", selection: Binding(get: { desk.zoom }, set: { desk.zoom = $0 })) {
                Text("Fit to window").tag(0.0); Text("Actual size (1:1)").tag(1.0); Text("150 %").tag(1.5); Text("200 %").tag(2.0)
            }
            Picker("Quality", selection: Binding(get: { desk.quality }, set: { desk.quality = $0 })) {
                Text("Fast (low quality)").tag(2); Text("Balanced").tag(6); Text("Sharp").tag(9)
            }
            Button { desk.reconnect() } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
            Toggle("Open when an agent uses the browser", isOn: Binding(get: { desk.followAgents }, set: { desk.followAgents = $0 }))
        } label: { Image(systemName: desk.zoom == 0 ? "arrow.up.left.and.down.right.magnifyingglass" : "plus.magnifyingglass").font(.system(size: 14, weight: .medium)).frame(width: 32, height: 32) }
        .help("Zoom, quality and reconnect")
    }

    var layoutButtons: some View {
        HStack(spacing: 0) {
            ForEach(DesktopStore.Presentation.allCases, id: \.self) { p in
                let on = desk.presentation == p
                Button { withAnimation(.snappy(duration: 0.25)) { desk.presentation = p } } label: {
                    Image(systemName: p.icon).font(.system(size: 13, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Theme.accent : Theme.textDim)
                        .frame(width: 30, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(p.help).accessibilityLabel(p.help).accessibilityIdentifier("desktop.layout.\(p.rawValue)")
            }
        }
        .background(Theme.hover.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
    }
}

extension DesktopStore.Presentation {
    var icon: String {
        switch self { case .split: return "rectangle.split.2x1"; case .floating: return "pip"; case .full: return "arrow.up.left.and.arrow.down.right"; case .mini: return "rectangle.bottomhalf.inset.filled" }
    }
    var help: String {
        switch self { case .split: return "Beside the workspace (⌃⌘\\)"; case .floating: return "Floating window (⌃⌘P)"; case .full: return "Full screen (⌃⌘F)"; case .mini: return "Minimise to a live thumbnail" }
    }
}

/// Typing and special keys for touch use (and keys the iPad keyboard lacks).
struct DesktopKeyBar: View {
    @Environment(DesktopStore.self) private var desk
    @State private var text = ""
    @State private var ctrl = false
    @State private var alt = false
    @State private var sup = false

    var body: some View {
        HStack(spacing: 4) {
            TextField("Type into the desktop", text: $text)
                .textInputAutocapitalization(.never).autocorrectionDisabled().font(Theme.mono)
                .onSubmit { send(text + "\n"); text = "" }
                .padding(.horizontal, 8).frame(height: 30).background(Theme.bg, in: RoundedRectangle(cornerRadius: 6))
                .frame(minWidth: 140)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    mod("Ctrl", $ctrl); mod("Alt", $alt); mod("Super", $sup)
                    key("Esc", 0xff1b); key("Tab", 0xff09); key("↩", 0xff0d); key("⌫", 0xff08)
                    key("←", 0xff51); key("↑", 0xff52); key("↓", 0xff54); key("→", 0xff53)
                    key("Home", 0xff50); key("End", 0xff57); key("PgUp", 0xff55); key("PgDn", 0xff56)
                    ForEach(1...12, id: \.self) { n in key("F\(n)", 0xffbd + n) }
                }
            }
        }
        .padding(6).background(Theme.raised)
    }

    func mods() -> [Int] { (ctrl ? [0xffe3] : []) + (alt ? [0xffe9] : []) + (sup ? [0xffeb] : []) }
    func send(_ s: String) {
        let m = mods()
        if m.isEmpty { desk.type(s) } else {
            for ch in s { if let v = ch.unicodeScalars.first?.value { desk.combo(m + [ch == "\n" ? 0xff0d : Int(v)]) } }
            ctrl = false; alt = false; sup = false
        }
    }
    func key(_ title: String, _ sym: Int) -> some View {
        Button(title) { desk.combo(mods() + [sym]); ctrl = false; alt = false; sup = false }
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .padding(.horizontal, 7).frame(height: 28).background(Theme.surface, in: RoundedRectangle(cornerRadius: 5))
            .buttonStyle(.plain)
    }
    func mod(_ title: String, _ on: Binding<Bool>) -> some View {
        Button(title) { on.wrappedValue.toggle() }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 7).frame(height: 28)
            .background(on.wrappedValue ? Theme.accent.opacity(0.25) : Theme.surface, in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(on.wrappedValue ? Theme.accent : Theme.text)
            .buttonStyle(.plain)
    }
}

/// Floating, full-screen and mini layouts, drawn over everything. The split
/// layout lives in the workspace shell (it takes room from the panels).
struct DesktopOverlay: View {
    let size: CGSize
    @Environment(DesktopStore.self) private var desk
    @State private var drag: CGSize = .zero
    @State private var resize: CGSize = .zero

    var body: some View {
        if desk.active {
            switch desk.presentation {
            case .split: EmptyView()
            case .full:
                DesktopPane(chrome: .full)
                    .ignoresSafeArea(.container, edges: .bottom)
                    .transition(.opacity)
                    .zIndex(10)
            case .floating: floating
            case .mini: mini
            }
        }
    }

    var floatRect: CGRect {
        let f = desk.floatFrame
        var w = max(300, f.width * size.width + resize.width), h = max(200, f.height * size.height + resize.height)
        w = min(w, size.width - 16); h = min(h, size.height - 16)
        var x = f.minX * size.width + drag.width, y = f.minY * size.height + drag.height
        x = min(max(8, x), size.width - w - 8); y = min(max(8, y), size.height - h - 8)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    var floating: some View {
        let r = floatRect
        return DesktopPane(chrome: r.width < 520 ? .compact : .full, onMove: { t, ended in
            if ended { commit(r); drag = .zero } else { drag = t }
        })
        .frame(width: r.width, height: r.height)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.lineStrong))
        .shadow(color: .black.opacity(0.28), radius: 22, y: 8)
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 10, weight: .bold)).rotationEffect(.degrees(90))
                .foregroundStyle(.white.opacity(0.8)).frame(width: 26, height: 26)
                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6)).padding(4)
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { resize = $0.translation }
                    .onEnded { _ in commit(floatRect); resize = .zero })
                .accessibilityLabel("Resize window")
                .accessibilityIdentifier("desktop.floating")
        }
        .position(x: r.midX, y: r.midY)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
        .zIndex(10)
    }

    var mini: some View {
        let w: CGFloat = min(260, size.width * 0.32), h = w * 0.62
        return ZStack(alignment: .topTrailing) {
            DesktopHost(store: desk).allowsHitTesting(false)
            HStack(spacing: 0) {
                Button { withAnimation(.snappy(duration: 0.25)) { desk.presentation = .floating } } label: { Image(systemName: "pip.exit").frame(width: 30, height: 28) }
                    .accessibilityLabel("Expand Remote Desktop").accessibilityIdentifier("desktop.mini")
                Button { desk.close() } label: { Image(systemName: "xmark").frame(width: 30, height: 28) }
            }
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 7)).padding(5)
            .buttonStyle(.plain)
        }
        .frame(width: w, height: h)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.lineStrong))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
        .onTapGesture { withAnimation(.snappy(duration: 0.25)) { desk.presentation = .floating } }
        .position(x: size.width - w / 2 - 14, y: size.height - h / 2 - 34)
        .transition(.scale(scale: 0.8, anchor: .bottomTrailing).combined(with: .opacity))
        .zIndex(10)
    }

    func commit(_ r: CGRect) {
        guard size.width > 0, size.height > 0 else { return }
        desk.floatFrame = CGRect(x: r.minX / size.width, y: r.minY / size.height, width: r.width / size.width, height: r.height / size.height)
    }
}
