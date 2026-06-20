import SwiftUI
import AppKit

// MARK: - App icon (DIRECTION 03 · "Pulse & breathing dot")
// Graphite squircle, monochrome white pulse, a single green liveness dot at the
// waveform's terminus — the same brand mark that beats in the menu bar.
// Resolution-independent: every dimension is a fraction of `side`, so a single
// view renders crisp at every iconset size. Ratios come from `PulseIcon.dc.html`:
//   corner 0.2237·side · stroke 0.07·side · dot ø 0.10·side · dot at (0.92, 0.58)
struct AppIconView: View {
    var side: CGFloat

    // macOS icon grid (Big Sur+): the rounded-rect body fills only ~80.5% of the
    // 1024² canvas (824² body, ~9.8% transparent padding per edge). Filling the
    // full canvas makes the icon render a size larger than every neighbouring app
    // in Finder/Dock/Launchpad, so the brand mark is inset into a centred body.
    var body: some View {
        let body = side * 0.8047
        ZStack {
            Color.clear
            IconBody(side: body)
                .frame(width: body, height: body)
        }
        .frame(width: side, height: side)
    }
}

// The squircle + waveform + liveness dot, sized entirely as fractions of its own
// edge so it renders crisp at any body size. `cornerRadius` ratio 0.2237 is
// Apple's body-corner ratio (185/824) — applied to the body, not the full canvas.
struct IconBody: View {
    var side: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: side * 0.2237, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: "#26262a"), Color(hex: "#161618")],
                                     startPoint: .top, endPoint: .bottom))

            PulseFullShape()
                .stroke(Color(hex: "#f2f2f4"),
                        style: StrokeStyle(lineWidth: side * 0.07, lineCap: .round, lineJoin: .round))

            Circle()
                .fill(Theme.liveGreen)
                .frame(width: side * 0.10, height: side * 0.10)
                .position(x: side * 0.92, y: side * 0.58)
        }
        .frame(width: side, height: side)
    }
}

// The brand waveform mapped across the full 0…100 design space onto the icon tile
// (unlike the menu-bar `HeartbeatShape`, which crops to the waveform's bbox).
struct PulseFullShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        for (i, pt) in PulseGlyph.points.enumerated() {
            let mapped = CGPoint(x: rect.minX + pt.x / 100 * rect.width,
                                 y: rect.minY + pt.y / 100 * rect.height)
            if i == 0 { p.move(to: mapped) } else { p.addLine(to: mapped) }
        }
        return p
    }
}

enum AppIconRenderer {
    // Apple's iconset manifest: (filename, pixel size). `iconutil -c icns` turns the
    // resulting `.iconset` directory into a multi-resolution `.icns`.
    private static let manifest: [(name: String, px: Int)] = [
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
    ]

    /// Writes a complete `.iconset` directory at `dir` (created if needed).
    @MainActor
    static func writeIconset(to dir: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var cache: [Int: Data] = [:]
        for entry in manifest {
            let png = cache[entry.px] ?? renderPNG(px: entry.px)
            cache[entry.px] = png
            if let png { try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(entry.name)) }
        }
    }

    /// Renders the icon at an exact pixel size. Frames the view in points and pins
    /// the renderer scale to 1 so output dimensions are exact (iconset is strict).
    @MainActor
    static func renderPNG(px: Int) -> Data? {
        let renderer = ImageRenderer(content: AppIconView(side: CGFloat(px)))
        renderer.scale = 1
        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return png
    }
}
