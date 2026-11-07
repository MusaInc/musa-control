import SwiftUI
import LocalAuthentication

/// Optional Face ID / passcode lock (Settings → Security). When on, the app
/// is covered whenever it returns from the background, so screenshots and
/// agent history aren't visible to someone picking up the iPad.
@MainActor
@Observable
final class AppLock {
    static let shared = AppLock()
    var enabled: Bool = UserDefaults.standard.bool(forKey: "lock.enabled") { didSet { UserDefaults.standard.set(enabled, forKey: "lock.enabled") } }
    var locked: Bool = UserDefaults.standard.bool(forKey: "lock.enabled")
    var error: String?

    func lock() { if enabled { locked = true } }

    func unlock() {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { locked = false; return }
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Musa Control") { ok, e in
            Task { @MainActor in
                if ok { self.locked = false; self.error = nil } else { self.error = e?.localizedDescription }
            }
        }
    }
}

struct LockOverlay: View {
    @State private var lock = AppLock.shared
    var body: some View {
        if lock.locked {
            ZStack {
                Theme.bg.ignoresSafeArea()
                VStack(spacing: 14) {
                    Image("SidebarMark").resizable().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 13))
                    Text("Musa Control is locked").font(Theme.title)
                    Button("Unlock") { lock.unlock() }.buttonStyle(.borderedProminent)
                    if let e = lock.error { Text(e).font(Theme.caption).foregroundStyle(Theme.textDim) }
                }
            }
            .onAppear { lock.unlock() }
            .transition(.opacity)
        }
    }
}
