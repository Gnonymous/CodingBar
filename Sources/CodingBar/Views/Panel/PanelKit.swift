import SwiftUI
import CodingBarCore

// MARK: - Panel constants & formatting (matches the v3 prototype's helpers)

enum Panel {
    static let width: CGFloat = 340
    static let hPad: CGFloat = 13

    private static let grp2: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.locale = Locale(identifier: "en_US")
        f.minimumFractionDigits = 2; f.maximumFractionDigits = 2; return f
    }()
    private static let grp0: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.locale = Locale(identifier: "en_US")
        f.minimumFractionDigits = 0; f.maximumFractionDigits = 0; return f
    }()

    /// "$1,234.56"
    static func usd(_ v: Double) -> String { "$" + (grp2.string(from: NSNumber(value: v)) ?? String(format: "%.2f", v)) }
    /// "$1,235" (rounded, grouped)
    static func usd0(_ v: Double) -> String { "$" + (grp0.string(from: NSNumber(value: v.rounded())) ?? "\(Int(v.rounded()))") }
    /// "6,637"
    static func int(_ n: Int) -> String { grp0.string(from: NSNumber(value: n)) ?? "\(n)" }

    /// Token shorthand, matching the prototype's `fmtTok`.
    static func tok(_ n: Int) -> String {
        let d = Double(n)
        if d >= 1e9 { return trimZeros(String(format: "%.2f", d / 1e9)) + "B" }
        if d >= 1e6 { return String(format: "%.1fM", d / 1e6) }
        if d >= 1e3 { let k = d / 1e3; return (k >= 100 ? "\(Int(k.rounded()))" : String(format: "%.1f", k)) + "K" }
        return "\(n)"
    }
    private static func trimZeros(_ s: String) -> String {
        guard s.contains(".") else { return s }
        var r = s; while r.hasSuffix("0") { r.removeLast() }; if r.hasSuffix(".") { r.removeLast() }; return r
    }

    /// "46 秒前" / "3 分钟前" / "2 小时前"
    static func age(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let s = max(0, now.timeIntervalSince(date))
        if s < 60 { return "\(Int(s)) 秒前" }
        if s < 3600 { return "\(Int(s / 60)) 分钟前" }
        if s < 86_400 { return "\(Int(s / 3600)) 小时前" }
        return "\(Int(s / 86_400)) 天前"
    }

    private static let hm: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    static func clock(_ date: Date) -> String { hm.string(from: date) }

    /// "重置 · 3 小时 12 分后" / "重置 · 明日 08:30" / "重置 · 周日 17:00"
    static func quotaReset(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let s = date.timeIntervalSince(now)
        if s <= 0 { return "重置 · 即将" }
        let cal = Calendar.current
        if s < 86_400 {
            let h = Int(s) / 3600, m = (Int(s) % 3600) / 60
            if h > 0 { return "重置 · \(h) 小时" + (m > 0 ? " \(m) 分" : "") + "后" }
            return "重置 · \(m) 分钟后"
        }
        let t = hm.string(from: date)
        if let tmr = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)),
           cal.isDate(date, inSameDayAs: tmr) {
            return "重置 · 明日 \(t)"
        }
        let wd = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][cal.component(.weekday, from: date) - 1]
        return "重置 · \(wd) \(t)"
    }

    /// Pretty quota-window label (prototype `niceLabel`).
    static func windowLabel(_ raw: String) -> String {
        switch raw {
        case "5h": return "5 小时"
        case "7d": return "7 天"
        case "7d·Opus": return "7 天 · Opus"
        case "7d·Sonnet": return "7 天 · Sonnet"
        default: return raw
        }
    }
}

// MARK: - Shared atoms

/// Section wrapper: top hairline + 12/13 padding (every prototype block).
struct DCSection<Content: View>: View {
    @Environment(\.dc) private var dc
    var topBorder: Bool = true
    var bottomPad: CGFloat = 12
    @ViewBuilder var content: Content
    init(topBorder: Bool = true, bottomPad: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.topBorder = topBorder; self.bottomPad = bottomPad; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if topBorder { Rectangle().fill(dc.sep).frame(height: 1) }
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, Panel.hPad)
                .padding(.top, 12)
                .padding(.bottom, bottomPad)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Uppercase 10.5pt/600 section label (fg2, letter-spaced).
struct DCLabel: View {
    @Environment(\.dc) private var dc
    let text: String
    var color: Color? = nil
    init(_ text: String, color: Color? = nil) { self.text = text; self.color = color }
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.525)
            .foregroundStyle(color ?? dc.fg2)
    }
}

/// Range segmented control (今日 / 7 天 / 30 天) — segbg track, selected pill raised.
struct DCRangeSeg: View {
    @Environment(\.dc) private var dc
    let selected: Range
    let onSelect: (Range) -> Void
    private let opts: [(Range, String)] = [(.today, "今日"), (.week, "7 天"), (.month, "30 天")]
    var body: some View {
        HStack(spacing: 1) {
            ForEach(opts, id: \.0) { r, label in
                let on = r == selected
                Button { onSelect(r) } label: {
                    Text(label)
                        .font(.system(size: 10.5, weight: on ? .semibold : .medium))
                        .foregroundStyle(on ? dc.fg : dc.fg2)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(on ? dc.segsel : Color.clear)
                                .shadow(color: on ? Color.black.opacity(0.18) : .clear, radius: 0.75, y: 0.5)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(dc.segbg))
    }
}
