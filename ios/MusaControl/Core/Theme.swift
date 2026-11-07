import SwiftUI

/// Visual language: dark charcoal surfaces, one warm accent, status colours
/// used only for status. Dense but with ≥ 32 pt hit targets.
enum Theme {
    static let bg = Color(red: 0.059, green: 0.063, blue: 0.071)          // window
    static let surface = Color(red: 0.090, green: 0.096, blue: 0.108)     // panels
    static let raised = Color(red: 0.122, green: 0.129, blue: 0.145)      // headers, cards
    static let hover = Color(red: 0.157, green: 0.165, blue: 0.184)
    static let line = Color.white.opacity(0.07)
    static let lineStrong = Color.white.opacity(0.12)
    static let text = Color(red: 0.918, green: 0.922, blue: 0.933)
    static let textDim = Color(red: 0.604, green: 0.616, blue: 0.651)
    static let textFaint = Color(red: 0.420, green: 0.431, blue: 0.463)
    static let accent = Color(red: 0.941, green: 0.749, blue: 0.478)      // warm amber
    static let green = Color(red: 0.369, green: 0.890, blue: 0.604)
    static let red = Color(red: 0.965, green: 0.408, blue: 0.408)
    static let yellow = Color(red: 0.980, green: 0.788, blue: 0.341)
    static let blue = Color(red: 0.459, green: 0.686, blue: 0.996)
    static let purple = Color(red: 0.725, green: 0.580, blue: 0.996)

    static let addedBg = Color(red: 0.369, green: 0.890, blue: 0.604).opacity(0.12)
    static let removedBg = Color(red: 0.965, green: 0.408, blue: 0.408).opacity(0.13)

    static let mono = Font.system(size: 12.5, design: .monospaced)
    static let monoSmall = Font.system(size: 11, design: .monospaced)
    static let label = Font.system(size: 12, weight: .medium)
    static let caption = Font.system(size: 11)
    static let title = Font.system(size: 15, weight: .semibold)
    static let radius: CGFloat = 8

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
        Text(text).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 4))
    }
}

struct SectionHeader: View {
    let title: String
    var trailing: AnyView? = nil
    var body: some View {
        HStack {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.textFaint)
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
            Image(systemName: icon).font(.system(size: 22, weight: .light)).foregroundStyle(Theme.textFaint)
            Text(text).font(Theme.label).foregroundStyle(Theme.textDim)
            if let detail { Text(detail).font(Theme.caption).foregroundStyle(Theme.textFaint).multilineTextAlignment(.center) }
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
            Image(systemName: systemName).font(.system(size: 13, weight: .medium)).foregroundStyle(tint)
                .frame(width: 30, height: 30).contentShape(Rectangle())
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
        padding(10).background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.radius))
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
