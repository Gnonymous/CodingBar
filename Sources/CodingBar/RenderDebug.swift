import SwiftUI
import AppKit
import CodingBarCore

// Offscreen rasterization of UI components for display-independent visual verification.
enum RenderDebug {
    @MainActor
    static func renderMenuBar(to path: String) {
        let samples = [
            MenuSummary(metric: .tokens, primaryText: "1.2M",   quotaPercent: 0.63, active: true,  throughput: 1400),
            MenuSummary(metric: .cost,   primaryText: "$4.20",  quotaPercent: 0.41, active: false, throughput: 0),
            MenuSummary(metric: .tokens, primaryText: "27.1M",  quotaPercent: 0.17, active: false, throughput: 0),
            MenuSummary(metric: .tokens, primaryText: "224.6M", quotaPercent: 0.44, active: false, throughput: 0),
            MenuSummary(metric: .tokens, primaryText: "500K",   quotaPercent: nil,  active: false, throughput: 0),
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
    static func renderPanel(to path: String, tab: Int, dark: Bool = true, scenario: String = "healthy",
                            metric: MenuMetric = .cost, language: AppLanguage = .en) {
        let store = UsageStore()
        store.language = language
        store.snapshot = Self.scenarioSnapshot(scenario, language: language)
        store.menuMetric = metric
        let view = PanelView(store: store, initialTab: tab, scrollable: false)
            .environment(\.colorScheme, dark ? .dark : .light)
        write(view, to: path, scale: 2)
    }

    @MainActor
    static func renderSettings(to path: String, dark: Bool = true, language: AppLanguage = .en) {
        let store = UsageStore()
        store.language = language
        store.snapshot = Self.scenarioSnapshot("healthy", language: language)
        let view = PanelView(store: store, scrollable: false, initialSettings: true)
            .environment(\.colorScheme, dark ? .dark : .light)
        write(view, to: path, scale: 2)
    }

    /// Mutate the sample snapshot into the prototype's named scenarios so every
    /// state (healthy / degraded / nosession / empty) can be rendered for review.
    @MainActor
    private static func scenarioSnapshot(_ name: String, language: AppLanguage = .en) -> Snapshot {
        var s = Snapshot.sample()
        // Per-provider freshness (recent successes by default). Keep the global badge
        // equal to the oldest provider, matching the runtime `global = min(...)` rule.
        s.quotaFetchedByProvider = [
            Provider.claude.rawValue: s.generatedAt.addingTimeInterval(-38),
            Provider.codex.rawValue: s.generatedAt.addingTimeInterval(-92),
        ]
        s.quotaFetchedAt = s.generatedAt.addingTimeInterval(-92)
        switch name {
        case "nosession":
            s.liveSessions = []; s.burnPerMin = 0
        case "degraded":
            s.quota = s.quota.filter { $0.provider == .codex }
            s.quotaNotes = [language.t("Claude usage API error HTTP 429 · re-login needed", "Claude 用量接口错误 HTTP 429 · 需重新登录")]
            s.quotaForecast = s.quotaForecast.filter { $0.key == "codex" }
            // Codex is on a stale last-good reading (kept through a failure streak).
            s.quotaFetchedByProvider = [Provider.codex.rawValue: s.generatedAt.addingTimeInterval(-8 * 60)]
            s.quotaFetchedAt = s.generatedAt.addingTimeInterval(-8 * 60)
        case "empty":
            s.liveSessions = []; s.burnPerMin = 0
            s.coach = [Insight(kind: .tip, text: language.t("Welcome to CodingBar! Keep coding — your spend, efficiency, and savings tips will appear here.", "欢迎使用 CodingBar！继续编码，这里会逐渐显示你的花费、效率与省钱建议。"))]
        default:
            break
        }
        return s
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
