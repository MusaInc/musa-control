import SwiftUI
import UIKit

/// Visual language: layered soft charcoal in dark mode, warm off-white in
/// light mode (never pure black or white), one warm accent, status colours
/// used only for status. Hierarchy comes from surface steps and type weight
/// rather than boxes; separators are hairlines.
enum Theme {
    /// Light/dark pair from RGB components.
    static func dyn(_ light: (Double, Double, Double), _ dark: (Double, Double, Double), alpha: Double = 1) -> Color {
        Color(UIColor { t in
            let c = t.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: alpha)
        })
    }
    static func uiDyn(_ light: (Double, Double, Double), _ dark: (Double, Double, Double)) -> UIColor {
        UIColor { t in let c = t.userInterfaceStyle == .dark ? dark : light; return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1) }
    }

    static let bg = dyn((0.957, 0.949, 0.933), (0.122, 0.125, 0.137))          // window: warm off-white / soft charcoal
    static let surface = dyn((0.984, 0.980, 0.969), (0.149, 0.153, 0.165))     // panels
    static let raised = dyn((0.929, 0.918, 0.898), (0.180, 0.184, 0.200))      // headers, cards, inputs
    static let hover = dyn((0.890, 0.878, 0.855), (0.220, 0.224, 0.243))       // selection
    static let line = dyn((0.0, 0.0, 0.0), (1.0, 1.0, 1.0), alpha: 0.075)
    static let lineStrong = dyn((0.0, 0.0, 0.0), (1.0, 1.0, 1.0), alpha: 0.14)
    static let text = dyn((0.114, 0.114, 0.122), (0.922, 0.922, 0.929))
    static let textDim = dyn((0.345, 0.349, 0.373), (0.678, 0.682, 0.710))      // ≥ 4.5:1 on surfaces
    static let textFaint = dyn((0.490, 0.494, 0.522), (0.537, 0.541, 0.569))    // metadata only
    static let accent = dyn((0.690, 0.431, 0.098), (0.937, 0.761, 0.506))       // warm amber
    static let onAccent = dyn((1, 1, 1), (0.122, 0.110, 0.090))                 // text on accent fills
    static let green = dyn((0.118, 0.557, 0.322), (0.443, 0.835, 0.604))
    static let red = dyn((0.788, 0.231, 0.231), (0.953, 0.478, 0.467))
    static let yellow = dyn((0.659, 0.471, 0.0), (0.949, 0.788, 0.408))
    static let blue = dyn((0.153, 0.420, 0.800), (0.502, 0.698, 0.973))
    static let purple = dyn((0.486, 0.333, 0.800), (0.722, 0.612, 0.965))

    static let addedBg = dyn((0.118, 0.557, 0.322), (0.443, 0.835, 0.604), alpha: 0.13)
    static let removedBg = dyn((0.788, 0.231, 0.231), (0.953, 0.478, 0.467), alpha: 0.13)

    /// Terminals and the agent screen mirror stay dark in both modes (ANSI
    /// colours assume it) but use the same soft charcoal, not black.
    static let terminalBg = UIColor(red: 0.118, green: 0.122, blue: 0.133, alpha: 1)
    static let terminalFg = UIColor(red: 0.886, green: 0.890, blue: 0.902, alpha: 1)
    static let editorBg = uiDyn((0.984, 0.980, 0.969), (0.149, 0.153, 0.165))

    static let mono = Font.system(size: 13, design: .monospaced)
    static let monoSmall = Font.system(size: 12, design: .monospaced)
    static let label = Font.system(size: 13, weight: .medium)
    static let caption = Font.system(size: 12)
    static let body = Font.system(size: 14.5)
    static let title = Font.system(size: 16, weight: .semibold)
    static let radius: CGFloat = 10

    static func status(_ s: String) -> Color {
        switch s {
        case "approval": return yellow
        case "working", "running", "in_progress", "queued": return blue
        case "idle", "succeeded", "success", "active", "completed": return green
        case "failed", "failure", "error", "cancelled": return red
        case "exited": return purple
        default: return textFaint
        }
    }
}

struct StatusDot: View {
    let status: String
    var size: CGFloat = 7
    var pulse: Bool { status == "working" || status == "running" || status == "approval" || status == "in_progress" }
    @State private var on = false
    var body: some View {
        Circle().fill(Theme.status(status)).frame(width: size, height: size)
            .overlay(Circle().stroke(Theme.status(status).opacity(pulse ? (on ? 0 : 0.6) : 0), lineWidth: 4).scaleEffect(on ? 2.2 : 1))
            .onAppear { if pulse { withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { on = true } } }
            .accessibilityLabel(Text(status))
    }
}

struct Pill: View {
    let text: String
    var color: Color = Theme.textDim
    var body: some View {
        Text(text).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(color).lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2.5)
            .background(color.opacity(0.14), in: Capsule())
    }
}

struct SectionHeader: View {
    let title: String
    var trailing: AnyView? = nil
    var body: some View {
        HStack {
            Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textDim)
            Spacer()
            if let trailing { trailing }
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
    }
}

struct EmptyNote: View {
    let icon: String
    let text: String
    var detail: String? = nil
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 26, weight: .light)).foregroundStyle(Theme.textFaint).padding(.bottom, 2)
            Text(text).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
            if let detail { Text(detail).font(Theme.caption).foregroundStyle(Theme.textDim).multilineTextAlignment(.center).frame(maxWidth: 380) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(20)
    }
}

/// Compact icon button with a comfortable hit area.
struct IconButton: View {
    let systemName: String
    var help: String = ""
    var tint: Color = Theme.textDim
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: 14, weight: .medium)).foregroundStyle(tint)
                .frame(width: 34, height: 34).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(help.isEmpty ? systemName : help))
        .hoverEffect(.highlight)
    }
}

extension View {
    func panelBackground() -> some View { background(Theme.surface) }
    func card() -> some View {
        padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.line))
    }
}

enum Fmt {
    static func ago(_ ms: Double?) -> String {
        guard let ms, ms > 0 else { return "—" }
        let s = max(0, Date().timeIntervalSince1970 - ms / 1000)
        if s < 45 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86400))d"
    }
    static func time(_ ms: Double?) -> String {
        guard let ms else { return "" }
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }
    static func bytes(_ b: Double?) -> String {
        guard let b else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
    }
    static func duration(_ secs: Double) -> String {
        if secs < 60 { return "\(Int(secs))s" }
        if secs < 3600 { return "\(Int(secs / 60))m \(Int(secs) % 60)s" }
        return "\(Int(secs / 3600))h \(Int(secs / 60) % 60)m"
    }
}
