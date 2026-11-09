import SwiftUI

// Motion for the studio stage: the camera, line transitions, the cursor
// trail, the typing bloom and the failure flare. Everything here is driven
// by something the director did in response to a real event, and all of it
// switches off (to plain cross-fades) with Reduce Motion, off-screen or in
// the background — see `stageAnimates`.

private struct StageAnimatesKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    /// False with Reduce Motion, while backgrounded, or when the stage isn't on screen.
    var stageAnimates: Bool {
        get { self[StageAnimatesKey.self] }
        set { self[StageAnimatesKey.self] = newValue }
    }
}

// MARK: - Camera

/// A gentle camera: leans in toward the window the agent is working in.
/// It zooms at most 6%, and never pans so far that the stage's edge shows.
enum StageCamera {
    struct Shot: Equatable {
        var scale: CGFloat = 1
        var offset: CGSize = .zero
    }

    static func shot(stage: CGSize, focus: CGRect?, maxZoom: CGFloat = 0.06) -> Shot {
        guard let f = focus, stage.width > 100, stage.height > 100, f.width > 1, f.height > 1 else { return Shot() }
        let share = min(1, (f.width * f.height) / (stage.width * stage.height))
        // Big windows barely zoom; small ones lean in a little more.
        let s: CGFloat = 1 + maxZoom * max(0, min(1, (0.75 - share) / 0.6))
        let mx = stage.width * (s - 1) / 2
        let my = stage.height * (s - 1) / 2
        let dx = (stage.width / 2 - f.midX) * s * 0.6
        let dy = (stage.height / 2 - f.midY) * s * 0.6
        return Shot(scale: s, offset: CGSize(width: min(mx, max(-mx, dx)), height: min(my, max(-my, dy))))
    }

    /// Where the stage's own rectangle lands after the shot (for tests: it
    /// must always still cover the viewport).
    static func covered(_ shot: Shot, stage: CGSize) -> CGRect {
        let w = stage.width * shot.scale, h = stage.height * shot.scale
        return CGRect(x: (stage.width - w) / 2 + shot.offset.width, y: (stage.height - h) / 2 + shot.offset.height, width: w, height: h)
    }
}

// MARK: - Line transitions

/// A line that just landed scans in from the left with a bright edge.
struct ScanInEffect: ViewModifier, Animatable {
    var progress: Double
    var tint: Color
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        let p = progress, t = tint
        content.visualEffect { c, proxy in
            c.layerEffect(ShaderLibrary.scanIn(.float2(proxy.size), .float(p), .color(t)), maxSampleOffset: .zero, isEnabled: p < 0.999)
        }
    }
}

/// A removed line dissolves into noise.
struct DissolveEffect: ViewModifier, Animatable {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        let p = progress
        content.layerEffect(ShaderLibrary.dissolve(.float(p)), maxSampleOffset: .zero, isEnabled: p > 0.001)
    }
}

extension AnyTransition {
    /// Added lines materialise, removed lines dissolve; a plain fade without motion.
    static func codeLine(_ tint: Color, animates: Bool) -> AnyTransition {
        guard animates else { return .opacity }
        return .asymmetric(
            insertion: .modifier(active: ScanInEffect(progress: 0, tint: tint), identity: ScanInEffect(progress: 1, tint: tint)),
            removal: .modifier(active: DissolveEffect(progress: 1), identity: DissolveEffect(progress: 0)))
    }
}

// MARK: - Failure flare

/// A short red flare over a view when `tick` changes (a failure landed).
struct FailureFlare: ViewModifier {
    let tick: Int
    let animates: Bool
    func body(content: Content) -> some View {
        if animates {
            content.keyframeAnimator(initialValue: 0.0, trigger: tick) { view, a in
                view.visualEffect { c, proxy in
                    c.colorEffect(ShaderLibrary.flare(.float2(proxy.size), .float(a), .color(Theme.red)), isEnabled: a > 0.01)
                }
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(1.0, duration: 0.08)
                    CubicKeyframe(0.0, duration: 0.8)
                }
            }
        } else {
            content
        }
    }
}

/// The stage's edges glow red for a moment when something fails.
struct StageFailureGlow: View {
    let tick: Int
    let animates: Bool
    var body: some View {
        GeometryReader { geo in
            Color.clear
                .keyframeAnimator(initialValue: 0.0, trigger: tick) { view, a in
                    view.overlay {
                        RadialGradient(colors: [.clear, Theme.red.opacity(0.28)], center: .center,
                                       startRadius: min(geo.size.width, geo.size.height) * 0.38,
                                       endRadius: max(geo.size.width, geo.size.height) * 0.75)
                            .opacity(animates ? a : 0)
                    }
                } keyframes: { _ in
                    KeyframeTrack {
                        LinearKeyframe(1.0, duration: 0.1)
                        CubicKeyframe(0.0, duration: 1.0)
                    }
                }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Cursor trail

/// A soft streak behind the cursor on long moves, fading as it arrives.
struct CursorTrailShape: Shape {
    var from: CGPoint
    var to: CGPoint
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(to.x, to.y) }
        set { to = CGPoint(x: newValue.first, y: newValue.second) }
    }
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: from)
        p.addLine(to: to)
        return p
    }
}

struct CursorTrail: View {
    let point: CGPoint
    let tint: Color
    @State private var from: CGPoint = .zero
    @State private var shown = 0.0

    var body: some View {
        CursorTrailShape(from: from, to: point)
            .stroke(tint.opacity(0.32), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .blur(radius: 1.5)
            .opacity(shown)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: point) { old, new in
                guard hypot(new.x - old.x, new.y - old.y) > 60 else { return }
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { from = old; shown = 1 }
                withAnimation(.easeOut(duration: 0.55).delay(0.2)) { shown = 0 }
            }
    }
}

// MARK: - Typing bloom

/// The character just typed glows briefly in its own syntax colour.
struct TypingBloom: View {
    let char: Character
    let color: Color
    let x: CGFloat
    let count: Int
    var body: some View {
        Text(String(char))
            .font(.system(size: 12.5, design: .monospaced))
            .foregroundStyle(color)
            .blur(radius: 2.2)
            .keyframeAnimator(initialValue: 1.0, trigger: count) { v, k in
                v.opacity(k).scaleEffect(1 + 0.5 * k)
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(1.0, duration: 0.01)
                    CubicKeyframe(0.0, duration: 0.32)
                }
            }
            .offset(x: x)
            .allowsHitTesting(false)
    }
}
