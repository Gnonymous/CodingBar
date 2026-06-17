import SwiftUI

// MARK: - Pulse / heartbeat glyph
// SVG path: M1 7 H4 L5.5 3.2 L7.7 10.8 L9.3 7 H15 (viewBox 0 0 16 14)
// The line itself is unchanged. A small "live" dot at the top-right breathes
// continuously (the design language's gentle opacity pulse); when an agent is
// actively writing the whole glyph also pulses, faster as throughput rises.
struct PulseIcon: View {
    var active: Bool
    var throughput: Double
    /// Live "breathing" dot color — driven by quota health (green → amber → red).
    /// nil falls back to the label color (monochrome).
    var dotColor: Color? = nil

    @State private var phase: Double = 0
    @State private var dotDim = false

    private var period: Double {
        let clamped = min(max(throughput, 0), 2000)
        return 1.6 - clamped / 2000   // 1.6s → 0.6s
    }

    var body: some View {
        ZStack {
            HeartbeatShape()
                .stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                .opacity(active ? 0.78 + 0.22 * sin(phase * .pi * 2) : 1.0)
            // "live" accent dot, top-right — colored by quota health, breathing.
            Circle()
                .fill(dotColor ?? Color(nsColor: .labelColor))
                .frame(width: 3, height: 3)
                .position(x: 14.4, y: 2.4)
                .opacity(dotDim ? 0.4 : 1.0)
        }
        .frame(width: 16, height: 14)
        .onAppear {
            if active { startPulsing() }
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) { dotDim = true }
        }
        .onChange(of: active) { _, isActive in
            if isActive { startPulsing() }
            else { withAnimation(.easeOut(duration: 0.3)) { phase = 0 } }
        }
    }

    private func startPulsing() {
        phase = 0
        withAnimation(.linear(duration: period).repeatForever(autoreverses: false)) { phase = 1 }
    }
}

struct HeartbeatShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 16, sy = rect.height / 14
        var p = Path()
        p.move(to:    CGPoint(x: 1   * sx, y: 7    * sy))
        p.addLine(to: CGPoint(x: 4   * sx, y: 7    * sy))
        p.addLine(to: CGPoint(x: 5.5 * sx, y: 3.2  * sy))
        p.addLine(to: CGPoint(x: 7.7 * sx, y: 10.8 * sy))
        p.addLine(to: CGPoint(x: 9.3 * sx, y: 7    * sy))
        p.addLine(to: CGPoint(x: 15  * sx, y: 7    * sy))
        return p
    }
}
