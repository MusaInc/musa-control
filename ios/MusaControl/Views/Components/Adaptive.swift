import SwiftUI
import UIKit

/// Layout helpers shared by every section so the same views work on an
/// iPad (side-by-side panes) and an iPhone (one pane at a time with Back).

private struct CompactLayoutKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True when the content area is phone-narrow (< 600 pt): iPhone, or an
    /// iPad window in Slide Over / a narrow Stage Manager window.
    var compactLayout: Bool {
        get { self[CompactLayoutKey.self] }
        set { self[CompactLayoutKey.self] = newValue }
    }
}

enum Device {
    static let isPhone: Bool = UIDevice.current.userInterfaceIdiom == .phone
    /// "iPhone" / "iPad" for user-facing copy.
    static var name: String { isPhone ? "iPhone" : "iPad" }
    static var osName: String { isPhone ? "iOS" : "iPadOS" }
    /// Light tap feedback for actions that change something on the server.
    @MainActor static func tap(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
    @MainActor static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }
}

/// Master list beside its detail when there's room; on narrow layouts the
/// list fills the screen and the detail replaces it (with a Back bar) while
/// `showingDetail` is true.
struct AdaptiveSplit<Master: View, Detail: View>: View {
    var masterWidth: CGFloat = 320
    var showingDetail: Bool
    var backTitle: String = "Back"
    var onBack: () -> Void
    @ViewBuilder var master: () -> Master
    @ViewBuilder var detail: () -> Detail
    @Environment(\.compactLayout) private var compact

    var body: some View {
        if compact {
            if showingDetail {
                VStack(spacing: 0) {
                    BackBar(title: backTitle, action: onBack)
                    detail().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .transition(.move(edge: .trailing))
            } else {
                master().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            HStack(spacing: 0) {
                master().frame(width: masterWidth)
                Divider().overlay(Theme.line)
                detail().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// A segmented choice that degrades to a horizontally scrolling chip row on
/// narrow layouts, where six segments would be unreadably small.
struct ChipPicker<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    @Environment(\.compactLayout) private var compact

    var body: some View {
        if compact {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(options.indices, id: \.self) { i in
                            let o = options[i]
                            let on = o.value == selection
                            Button { withAnimation(.snappy(duration: 0.18)) { selection = o.value } } label: {
                                Text(o.title).font(.system(size: 13.5, weight: on ? .semibold : .regular))
                                    .padding(.horizontal, 12).frame(height: 32)
                                    .background(on ? Theme.accent.opacity(0.18) : Theme.hover, in: Capsule())
                                    .foregroundStyle(on ? Theme.accent : Theme.textDim)
                            }
                            .buttonStyle(.plain).id(i)
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .onAppear { if let i = options.firstIndex(where: { $0.value == selection }) { proxy.scrollTo(i, anchor: .center) } }
            }
            .padding(.vertical, 6)
        } else {
            Picker("", selection: $selection) {
                ForEach(options.indices, id: \.self) { i in Text(options[i].title).tag(options[i].value) }
            }
            .pickerStyle(.segmented).padding(8)
        }
    }
}

extension View {
    /// Toolbars full of buttons scroll sideways on narrow layouts instead of
    /// squeezing their labels to nothing.
    @ViewBuilder func scrollsWhenCompact(_ compact: Bool) -> some View {
        if compact { ScrollView(.horizontal, showsIndicators: false) { self } } else { self }
    }
}

/// Icon + title normally; icon only where space is tight.
struct CompactLabelStyle: LabelStyle {
    var iconOnly: Bool
    func makeBody(configuration: Configuration) -> some View {
        if iconOnly { configuration.icon } else { HStack(spacing: 6) { configuration.icon; configuration.title } }
    }
}
