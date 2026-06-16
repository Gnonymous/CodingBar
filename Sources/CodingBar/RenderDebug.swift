import SwiftUI
import AppKit
import CodingBarCore

// Offscreen rasterization of UI components for display-independent visual verification.
enum RenderDebug {
    @MainActor
    static func renderMenuBar(to path: String) {
        let samples = [
            MenuSummary(metric: .tokens, primaryText: "1.2M",  quotaPercent: 0.63, active: true,  throughput: 1400),
            MenuSummary(metric: .cost,   primaryText: "$4.20", quotaPercent: 0.41, active: false, throughput: 0),
            MenuSummary(metric: .tokens, primaryText: "27.1M", quotaPercent: 0.17, active: false, throughput: 0),
            MenuSummary(metric: .tokens, primaryText: "500K",  quotaPercent: nil,  active: false, throughput: 0),
        ]
        let view = HStack(spacing: 30) {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, m in
                MenuBarItemView(menu: m)
            }
        }
        .padding(22)
        .background(Color(red: 0.10, green: 0.11, blue: 0.13))
        .environment(\.colorScheme, .dark)

        write(view, to: path, scale: 6)
    }

    @MainActor
    static func renderPanel(to path: String, tab: Int) {
        let store = UsageStore()   // initialized with Snapshot.sample()
        let view = PanelView(store: store, initialTab: tab, scrollable: false, onQuit: {})
            .environment(\.colorScheme, .dark)
        write(view, to: path, scale: 2)
    }

    @MainActor
    private static func write<V: View>(_ view: V, to path: String, scale: CGFloat) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("render failed\n".utf8)); return
        }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
