import SwiftUI

// MARK: - Pulse / heartbeat glyph
// SVG path: M1 7 H4 L5.5 3.2 L7.7 10.8 L9.3 7 H15 (viewBox 0 0 16 14)
// When active, a subtle brightness pulse animates; period shortens with throughput.
struct PulseIcon: View {
    var active: Bool
    var throughput: Double

    @State private var phase: Double = 0

    private var period: Double {
        let clamped = min(max(throughput, 0), 2000)
        return 1.6 - clamped / 2000 * 1.0   // 1.6s → 0.6s
    }

    var body: some View {
        HeartbeatShape()
            .stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            .frame(width: 15, height: 14)
            .opacity(active ? 0.7 + 0.3 * sin(phase * .pi * 2) : 0.92)
            .onAppear { if active { startPulsing() } }
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

private struct HeartbeatShape: Shape {
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
