import SwiftUI
import CodingBarCore

// MARK: - Design tokens mirroring the v3 prototype (SpendPopoverTabbed.dc.html)
// Every value is taken verbatim from the prototype's `themeVarsFor()` so the panel
// matches pixel-for-pixel in both appearances.
struct DCTheme {
    let bg, navbg, elev, fg, fg2, fg3: Color
    let sep, sep2, track, accent, segbg, segsel: Color
    let good, warn, bad, hover, edge: Color
    let warnBg, warnBorder, tipBg, tipBorder: Color

    // Theme-independent accents (fixed in the prototype regardless of appearance).
    let claude = Color(hex: "#c2773f")
    let codex  = Color(hex: "#3a9d8f")

    // Fixed (theme-independent) hues the prototype hard-codes into badge tints,
    // delta pills, sparkline area, and heatmap — they do NOT follow --good/--accent.
    let fixedGood = Color(hex: "#2faa4f")     // rgb(47,170,79)
    let fixedWarn = Color(hex: "#cf8a12")     // rgb(207,138,18)
    let fixedAccent = Color(hex: "#007aff")   // rgb(0,122,255)
    let fixedBlue = Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255)  // rgba(10,132,255,…)

    func provider(_ p: Provider) -> Color { p == .claude ? claude : codex }

    /// Fixed badge-tint background for a coach insight kind (HTML `coachIcon`).
    func coachIconBg(_ kind: InsightKind) -> Color {
        switch kind {
        case .tip: return fixedGood.opacity(0.16)
        case .forecast: return fixedWarn.opacity(0.16)
        case .milestone: return fixedAccent.opacity(0.16)
        }
    }

    /// Quota severity by *used* fraction (≥90% bad / ≥75% warn / else good).
    func usedSev(_ used: Double) -> Color { used >= 0.90 ? bad : (used >= 0.75 ? warn : good) }
    /// Context-fill severity (>85% bad / >70% warn / else accent).
    func barSev(_ ratio: Double) -> Color { ratio > 0.85 ? bad : (ratio > 0.70 ? warn : accent) }

    static let dark = DCTheme(
        bg: Color(hex: "#1d1d1f"), navbg: Color(hex: "#191919"), elev: .white.opacity(0.06),
        fg: Color(hex: "#f2f2f4"), fg2: Color(hex: "#9b9ba1"), fg3: Color(hex: "#6a6a70"),
        sep: .white.opacity(0.10), sep2: .white.opacity(0.06), track: .white.opacity(0.12),
        accent: Color(hex: "#0a84ff"), segbg: .white.opacity(0.08), segsel: .white.opacity(0.18),
        good: Color(hex: "#30d158"), warn: Color(hex: "#ff9f0a"), bad: Color(hex: "#ff453a"),
        hover: .white.opacity(0.07), edge: .white.opacity(0.10),
        warnBg: Color(hex: "#ff9f0a").opacity(0.12), warnBorder: Color(hex: "#ff9f0a").opacity(0.32),
        tipBg: Color(hex: "#0a84ff").opacity(0.10), tipBorder: Color(hex: "#0a84ff").opacity(0.28))

    static let light = DCTheme(
        bg: Color(hex: "#f6f6f7"), navbg: Color(hex: "#fbfbfc"), elev: Color(hex: "#ffffff"),
        fg: Color(hex: "#1c1c1e"), fg2: Color(hex: "#6b6b70"), fg3: Color(hex: "#9b9ba0"),
        sep: .black.opacity(0.08), sep2: .black.opacity(0.05), track: .black.opacity(0.08),
        accent: Color(hex: "#007aff"), segbg: .black.opacity(0.06), segsel: Color(hex: "#ffffff"),
        good: Color(hex: "#2faa4f"), warn: Color(hex: "#cf8a12"), bad: Color(hex: "#d6453a"),
        hover: .black.opacity(0.045), edge: .black.opacity(0.14),
        warnBg: Color(hex: "#cf8a12").opacity(0.10), warnBorder: Color(hex: "#cf8a12").opacity(0.30),
        tipBg: Color(hex: "#007aff").opacity(0.07), tipBorder: Color(hex: "#007aff").opacity(0.22))

    // Delta pill backgrounds (fixed rgba in the prototype, both themes).
    var deltaUpBg: Color { Color(hex: "#d98a14").opacity(0.15) }   // rgb(217,138,20)
    var deltaDownBg: Color { fixedGood.opacity(0.15) }
}

private struct DCThemeKey: EnvironmentKey { static let defaultValue = DCTheme.dark }
extension EnvironmentValues {
    var dc: DCTheme { get { self[DCThemeKey.self] } set { self[DCThemeKey.self] = newValue } }
}

// MARK: - Breathing dot
// The prototype is full of `sbtblink` (opacity 1 → .35 → 1 over ~1.5s) accents:
// the header status dot, the burn dot, and each parallel-session dot (staggered by
// 0.4s). This reusable view reproduces that breath.
struct BreathingDot: View {
    var size: CGFloat
    var color: Color
    var animate: Bool = true
    var delay: Double = 0
    @State private var dim = false
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(animate ? (dim ? 0.35 : 1.0) : 1.0)
            .onAppear {
                guard animate else { return }
                withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true).delay(delay)) {
                    dim = true
                }
            }
            .onChange(of: animate) { _, on in
                if on {
                    withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) { dim = true }
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { dim = false }
                }
            }
    }
}
