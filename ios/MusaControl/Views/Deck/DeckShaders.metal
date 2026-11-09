#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Shaders for the Command Deck and the studio stage. Each one is cheap
// (a few octaves of value noise at most) and the views that use them run
// them at 30 fps or only while an effect is playing.

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i), b = hash21(i + float2(1, 0)), c = hash21(i + float2(0, 1)), d = hash21(i + float2(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static float fbm(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 4; i++) {
        v += a * vnoise(p);
        p = p * 2.03 + float2(1.7, 9.2);
        a *= 0.5;
    }
    return v;
}

/// Ambient field behind the deck: slow topographic contours that drift and
/// brighten with total agent activity (`energy` 0…1). At energy 0 the field
/// is a faint, still map.
[[ stitchable ]] half4 deckField(float2 pos, half4 color, float2 size, float time, float energy, half4 warm, half4 cool) {
    float2 uv = pos / max(size.x, size.y);
    float t = time;   // phase, integrated on the CPU so speed changes never jump
    float2 q = float2(fbm(uv * 2.6 + float2(t, 0.0)), fbm(uv * 2.6 + float2(4.1, -t)));
    float n = fbm(uv * 2.0 + q * 1.5 + float2(0.0, t * 0.6));
    float band = abs(fract(n * 9.0) - 0.5);
    float contour = 1.0 - smoothstep(0.0, 0.045, band);
    float glow = smoothstep(0.42, 0.85, n);
    float k = contour * (0.05 + 0.10 * energy) + glow * (0.02 + 0.07 * energy);
    half3 ink = mix(warm.rgb, cool.rgb, half(smoothstep(0.3, 0.75, q.x)));
    half a = half(clamp(k, 0.0, 0.22));
    return half4(mix(color.rgb, ink * color.a, a), color.a);
}

/// Scan-in for a line that just landed: a bright band sweeps left to right
/// and the text behind it materialises. `progress` 0…1.
[[ stitchable ]] half4 scanIn(float2 pos, SwiftUI::Layer layer, float2 size, float progress, half4 tint) {
    half4 c = layer.sample(pos);
    float x = pos.x / max(size.x, 1.0);
    float edge = progress * 1.25 - 0.1;
    float shown = 1.0 - smoothstep(edge - 0.06, edge + 0.02, x);
    float dx = (x - edge) * 14.0;
    float band = exp(-dx * dx) * (1.0 - progress);
    float scan = 0.85 + 0.15 * sin(pos.y * 3.14159);
    half4 out = c * half(shown * scan);
    out.rgb += tint.rgb * half(band * 0.55) * c.a;
    return out;
}

/// Dissolve for removed lines: noise-thresholded fade. `progress` 0…1.
[[ stitchable ]] half4 dissolve(float2 pos, SwiftUI::Layer layer, float progress) {
    half4 c = layer.sample(pos);
    float n = vnoise(pos * 0.35);
    float keep = smoothstep(progress - 0.08, progress + 0.08, n);
    return c * half(keep);
}

/// Red flare on failure: a soft vignette that pulses in and fades. `amount` 0…1.
[[ stitchable ]] half4 flare(float2 pos, half4 color, float2 size, float amount, half4 tint) {
    float2 uv = pos / size - 0.5;
    float v = smoothstep(0.25, 0.75, length(uv * float2(1.0, size.y / max(size.x, 1.0)) * 1.6));
    half a = half(v * amount * 0.45);
    return half4(mix(color.rgb, tint.rgb * color.a, a), color.a);
}

/// Parallax heat shimmer used by the camera while it glides: offsets pixels
/// by a tiny amount along the motion direction. `amount` in points.
[[ stitchable ]] float2 glide(float2 pos, float2 dir, float amount) {
    float w = sin(pos.y * 0.03) * 0.5 + 0.5;
    return pos + dir * amount * w;
}
