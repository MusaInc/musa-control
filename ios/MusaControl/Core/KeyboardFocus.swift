import UIKit
import Observation
import GameController
import SwiftTerm

/// Where typing goes right now: a terminal, the editor, the remote desktop
/// or a text field. Shown in the status bar so a hardware keyboard never
/// types into the wrong place. Read from the real first responder.
@MainActor
@Observable
final class KeyboardFocus {
    static let shared = KeyboardFocus()
    enum Target: Equatable {
        case none, terminal(String), editor(String), desktop(remoteShortcuts: Bool), text
        var label: String {
            switch self {
            case .none: return "No keyboard focus"
            case .terminal(let t): return "Terminal · \(t)"
            case .editor(let p): return "Editor · \((p as NSString).lastPathComponent)"
            case .desktop(let r): return r ? "Remote Desktop · ⌘ → Ctrl" : "Remote Desktop"
            case .text: return "Text field"
            }
        }
        var icon: String {
            switch self {
            case .none: return "keyboard"
            case .terminal: return "terminal"
            case .editor: return "chevron.left.forwardslash.chevron.right"
            case .desktop: return "display"
            case .text: return "character.cursor.ibeam"
            }
        }
    }
    private(set) var target: Target = .none
    private(set) var hardwareKeyboard = GCKeyboard.coalesced != nil
    @ObservationIgnored private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        NotificationCenter.default.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.hardwareKeyboard = true } }
        NotificationCenter.default.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.hardwareKeyboard = GCKeyboard.coalesced != nil } }
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
    }

    func poll() {
        let t = classify(UIResponder.currentFirst)
        if t != target { target = t }
    }

    private func classify(_ r: UIResponder?) -> Target {
        guard let r else { return .none }
        var view = r as? UIView
        while let v = view {
            if let d = v as? DesktopWebView { return .desktop(remoteShortcuts: d.store?.interceptsCommandKeys ?? false) }
            if let t = v as? SwiftTerm.TerminalView { return .terminal(TerminalStore.shared.owner(of: t)?.title ?? "shell") }
            if let e = v as? EditorTextView { return .editor(e.sourcePath) }
            view = v.superview
        }
        if r is UITextField || r is UITextView { return .text }
        return .none
    }
}

extension UIResponder {
    private static weak var found: UIResponder?
    /// The current first responder (nil when nothing has focus).
    static var currentFirst: UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(captureFirst), to: nil, from: nil, for: nil)
        return found
    }
    @objc private func captureFirst() { UIResponder.found = self }
}
