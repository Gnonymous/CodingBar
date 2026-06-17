import SwiftUI
import AppKit

// Matches mockups/menubar-numbers-v4.html and docs/superpowers/specs/2026-06-17-codingbar-design.md §6.3
enum Theme {
    // Brand
    static let brandAmber = Color(hex: "#e0925f")

    // Output delta
    static let gain = Color(hex: "#5fb98a")
    static let loss = Color(hex: "#d97a72")

    // Quota bar fill
    static let quotaGreen = Color(hex: "#46c97f")
    static let quotaAmber = Color(hex: "#ffb23e")
    static let quotaRed   = Color(hex: "#ff5a52")

    // Provider tints (small dots only)
    static let claudeColor = Color(hex: "#dd8a5a")
    static let codexColor  = Color(hex: "#6aa6dd")

    // Text hierarchy (label-adaptive)
    static var primaryText: Color { Color(nsColor: .labelColor) }
    static var dimText: Color { Color(nsColor: .secondaryLabelColor) }
    static var faintText: Color { Color(nsColor: .tertiaryLabelColor) }

    // Surfaces
    static let popoverBackground = Color(nsColor: .windowBackgroundColor)
    static let hairline = Color(nsColor: .separatorColor)

    // Quota bar track (adapts appearance)
    static func quotaTrack(scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.14)
    }

    // Quota fill color by remaining fraction (0…1)
    static func quotaColor(_ remaining: Double) -> Color {
        switch remaining {
        case 0.50...: return quotaGreen
        case 0.25..<0.50: return quotaAmber
        default: return quotaRed
        }
    }

    // Fonts — 10pt semibold tabular for the menu bar lines
    static let menuBarFont = Font.system(size: 10, weight: .semibold).monospacedDigit()
}

extension Color {
    init(hex: String) {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let v = UInt64(h, radix: 16) ?? 0
        self.init(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }
}
