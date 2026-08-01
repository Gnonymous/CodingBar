import SwiftUI

// MARK: - The brand pulse waveform (DIRECTION 03)
// The single source of truth for the ECG glyph that both the menu-bar icon and
// the app icon draw, so they are literally the same mark. Coordinates live in the
// app icon's 0…100 design space (from `App Icon.dc.html` / `PulseIcon.dc.html`):
//   8,58 32,58 39,47 46,58 53,58 60,74 68,22 76,66 83,58 92,58
// Flat baseline → a small dip-bump → a deep beat (down to 74, spike up to 22) →
// overshoot → settle. The live dot caps the right terminus at (92, 58).
enum PulseGlyph {
    static let points: [CGPoint] = [
        CGPoint(x: 8,  y: 58), CGPoint(x: 32, y: 58), CGPoint(x: 39, y: 47),
        CGPoint(x: 46, y: 58), CGPoint(x: 53, y: 58), CGPoint(x: 60, y: 74),
        CGPoint(x: 68, y: 22), CGPoint(x: 76, y: 66), CGPoint(x: 83, y: 58),
        CGPoint(x: 92, y: 58),
    ]
    /// The waveform's right terminus, where the breathing dot sits.
    static let terminus = CGPoint(x: 92, y: 58)

    // Tight bounding box of the stroked path, used to map the waveform into a
    // target rect without dead margins (the menu-bar glyph fills its box).
    static let minX: CGFloat = 8,  spanX: CGFloat = 84   // 8 … 92
    static let minY: CGFloat = 22, spanY: CGFloat = 52   // 22 … 74

    /// Normalized (0…1) position of a design-space point within the bounding box.
    static func normalized(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - minX) / spanX, y: (p.y - minY) / spanY)
    }
}

// MARK: - Pulse / heartbeat glyph (still frame)
// Monochrome white/black pulse (template — tinted by the menu-bar appearance via
// the caller's foregroundStyle) with a single green liveness dot at the right
// terminus: green when an agent is active, steady gray when idle.
//
// This is the *static* rendition, used by the offscreen renderer and anywhere the mark
// appears outside the status item. The live menu-bar glyph is `PulseLayerView`, which
// breathes via Core Animation — a SwiftUI animation inside the NSStatusItem re-lays-out
// the entire item every frame (measured: 60% of a core). Both read `PulseGlyph`, so the
// mark is identical.
struct PulseIcon: View {
    var active: Bool

    // Glyph box. The waveform fills an inset rect; the dot caps the right end and
    // pokes a hair past it, so the box leaves room on the right for the dot.
    private let box = CGSize(width: 18, height: 13)
    private let lineWidth: CGFloat = 1.5
    private let dotRadius: CGFloat = 1.7

    // Inner rect the waveform maps into (leaves room for the round caps and the
    // dot's radius on the right). The dot's center is the waveform's terminus.
    private var inner: CGRect {
        CGRect(x: lineWidth / 2,
               y: lineWidth / 2,
               width: box.width - lineWidth - dotRadius,
               height: box.height - lineWidth)
    }
    private var dotCenter: CGPoint {
        let n = PulseGlyph.normalized(PulseGlyph.terminus)
        return CGPoint(x: inner.minX + n.x * inner.width,
                       y: inner.minY + n.y * inner.height)
    }
    private var dotColor: Color { active ? Theme.liveGreen : Color(nsColor: .tertiaryLabelColor) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            HeartbeatShape()
                .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                .frame(width: inner.width, height: inner.height)
                .offset(x: inner.minX, y: inner.minY)

            Circle()
                .fill(dotColor)
                .frame(width: dotRadius * 2, height: dotRadius * 2)
                .position(dotCenter)
        }
        .frame(width: box.width, height: box.height)
    }
}

// Maps the brand waveform's bounding box onto the given rect (used by the menu-bar
// glyph so the pulse fills its inset box tightly).
struct HeartbeatShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        for (i, point) in PulseGlyph.points.enumerated() {
            let n = PulseGlyph.normalized(point)
            let pt = CGPoint(x: rect.minX + n.x * rect.width,
                             y: rect.minY + n.y * rect.height)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}
