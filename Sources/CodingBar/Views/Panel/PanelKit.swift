import SwiftUI
import CodingBarCore

// MARK: - Shared panel constants & formatting

enum Panel {
    static let width: CGFloat = 380
    static let hPad: CGFloat = 16

    static func money(_ v: Double) -> String {
        if v >= 100 { return String(format: "$%.0f", v) }
        return String(format: "$%.2f", v)
    }
    static func tokens(_ n: Int) -> String { UsageStore.humanTokens(n) }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(date))
        if s < 90 { return "刚刚" }
        if s < 3600 { return "\(Int(s/60))m前" }
        if s < 86_400 { return "\(Int(s/3600))h前" }
        let d = Int(s/86_400)
        return d == 1 ? "昨天" : "\(d)天前"
    }

    static func reset(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let s = date.timeIntervalSince(now)
        if s <= 0 { return "即将" }
        if s < 3600 { return "\(Int(s/60))m" }
        if s < 86_400 { return String(format: "%.0fh", s/3600) }
        return "\(Int(s/86_400))天"
    }
}

// MARK: - Section header (mono uppercase label + optional trailing accessory)

struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(Theme.faintText)
            Spacer()
            trailing
        }
    }
}
extension SectionHeader where Trailing == EmptyView {
    init(_ title: String) { self.init(title: title) { EmptyView() } }
}

// MARK: - Horizontal progress bar

struct HBar: View {
    var fraction: Double
    var color: Color
    var height: CGFloat = 7
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color)
                    .frame(width: max(geo.size.width * min(max(fraction, 0), 1), height))
            }
        }
        .frame(height: height)
    }
}

// MARK: - Quota row

struct QuotaRow: View {
    let window: QuotaWindow
    var now: Date = Date()
    private var providerColor: Color { window.provider == .claude ? Theme.claudeColor : Theme.codexColor }
    private var label: String { (window.provider == .claude ? "Claude " : "Codex ") + window.label }
    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(providerColor).frame(width: 7, height: 7)
                Text(label).font(.system(size: 12)).foregroundStyle(Theme.dimText)
            }
            .frame(width: 78, alignment: .leading)
            HBar(fraction: window.remaining, color: Theme.quotaColor(window.remaining))
            Text("\(Int((window.remaining*100).rounded()))%")
                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.quotaColor(window.remaining))
                .frame(width: 34, alignment: .trailing)
            Text(Panel.reset(window.resetAt, now: now))
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(Theme.faintText)
                .frame(width: 40, alignment: .trailing)
        }
    }
}

// MARK: - Stat cell (rhythm)

struct StatCell: View {
    let value: String
    let unit: String?
    let label: String
    init(_ value: String, unit: String? = nil, label: String) { self.value = value; self.unit = unit; self.label = label }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value).font(.system(size: 18, weight: .bold).monospacedDigit())
                    .foregroundStyle(Theme.primaryText)
                if let unit { Text(unit).font(.system(size: 11)).foregroundStyle(Theme.faintText) }
            }
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.faintText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.hairline, lineWidth: 1))
    }
}

// MARK: - Breakdown row (projects / models)

struct BreakdownRow: View {
    let name: String
    var dot: Color? = nil
    let fraction: Double
    let barColor: Color
    let value: String
    var nameWidth: CGFloat = 110
    var valueWidth: CGFloat = 104
    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
                Text(name).font(.system(size: 12.5)).foregroundStyle(Theme.primaryText).lineLimit(1)
            }
            .frame(width: nameWidth, alignment: .leading)
            HBar(fraction: fraction, color: barColor)
            Text(value).font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(Theme.dimText)
                .frame(width: valueWidth, alignment: .trailing)
        }
    }
}
