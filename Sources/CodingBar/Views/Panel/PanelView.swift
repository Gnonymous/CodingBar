import SwiftUI
import AppKit
import CodingBarCore

// MARK: - The popover panel (v3 — SpendPopoverTabbed.dc.html)
// Header · active tab (总览 / 构成 / 洞察) · provenance · bottom nav.
struct PanelView: View {
    @ObservedObject var store: UsageStore
    @Environment(\.colorScheme) private var systemScheme
    @State private var tab: Int
    @State private var refreshSpin: Double = 0
    @State private var contentHeight: CGFloat = 0
    @State private var showSettings = false
    /// Live popover scrolls within a screen-bounded height; offscreen rendering
    /// (ImageRenderer has no update pass) uses natural height instead.
    let scrollable: Bool

    init(store: UsageStore, initialTab: Int = 0, scrollable: Bool = true, initialSettings: Bool = false) {
        self.store = store
        self._tab = State(initialValue: initialTab)
        self.scrollable = scrollable
        self._showSettings = State(initialValue: initialSettings)
    }

    private var snap: Snapshot { store.snapshot }
    // Appearance follows the system (the popover inherits NSApp.effectiveAppearance).
    private var dc: DCTheme { systemScheme == .dark ? .dark : .light }
    private var burning: Bool { !snap.liveSessions.isEmpty }
    private var statusText: String { burning ? "\(snap.liveSessions.count) 会话" : "空闲" }

    /// Cap the scrollable region so a tall tab can't push the popover off-screen
    /// (header / provenance / nav stay pinned; only the tab body scrolls).
    private var maxContentHeight: CGFloat {
        let h = NSScreen.main?.visibleFrame.height ?? 900
        return max(360, h - 170)
    }

    var body: some View {
        Group {
            if showSettings {
                SettingsView(store: store, onClose: { showSettings = false })
            } else {
                mainPanel
            }
        }
        .frame(width: Panel.width)
        .background(dc.bg)
        .environment(\.dc, dc)
    }

    private var mainPanel: some View {
        VStack(spacing: 0) {
            header
            if scrollable {
                ScrollView(.vertical, showsIndicators: false) {
                    tabContent
                        .background(GeometryReader { g in
                            Color.clear.preference(key: ContentHeightKey.self, value: g.size.height)
                        })
                }
                .frame(height: contentHeight > 0 ? min(contentHeight, maxContentHeight) : nil)
                .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
            } else {
                tabContent
            }
            provenance
            bottomNav
        }
    }

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case 1: CostTab(store: store)
        case 2: InsightsTab(store: store)
        default: OverviewTab(store: store, onShowInsights: { tab = 2 })
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            brandMark
            Text("CodingBar").font(.system(size: 13, weight: .semibold)).tracking(-0.13).foregroundStyle(dc.fg)
            HStack(spacing: 5) {
                BreathingDot(size: 6, color: burning ? dc.good : dc.fg3, animate: burning)
                Text(statusText).font(.system(size: 10.5)).foregroundStyle(dc.fg2)
            }
            .padding(.leading, 6).padding(.trailing, 7).padding(.vertical, 2)
            .background(Capsule().fill(dc.hover))
            Spacer()
            metricToggle
            Button { doRefresh() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .regular)).foregroundStyle(dc.fg3)
                    .rotationEffect(.degrees(refreshSpin))
                    .padding(.horizontal, 3).padding(.vertical, 1)
            }
            .buttonStyle(.plain).focusEffectDisabled()
            // Settings gear — same size / weight / color / padding as the refresh and
            // metric buttons so the three read as one matched cluster in the corner.
            Button { showSettings = true } label: {
                Image(systemName: "gearshape").font(.system(size: 9, weight: .regular)).foregroundStyle(dc.fg3)
                    .padding(.horizontal, 3).padding(.vertical, 1).contentShape(Rectangle())
            }
            .buttonStyle(.plain).focusEffectDisabled().help("设置")
        }
        .padding(.horizontal, 13).padding(.top, 11).padding(.bottom, 10)
    }

    /// Metric toggle (花费 ⇄ Token) — same size / weight / color / padding as the
    /// refresh button so the two read as a matched pair. The icon shows the
    /// *current* metric; tapping flips both the panel and the menu bar.
    private var metricToggle: some View {
        let isCost = store.menuMetric == .cost
        return Button { store.toggleMetric() } label: {
            Image(systemName: isCost ? "dollarsign" : "number")
                .font(.system(size: 9, weight: .regular)).foregroundStyle(dc.fg3)
                .padding(.horizontal, 3).padding(.vertical, 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).focusEffectDisabled()
        .help(isCost ? "当前显示：花费 · 点击切换为 Token" : "当前显示：Token · 点击切换为花费")
    }

    /// CodingBar's own mark: the pulse heartbeat on an accent tile (our identity,
    /// not the prototype's terminal "›").
    private var brandMark: some View {
        RoundedRectangle(cornerRadius: 5).fill(dc.accent)
            .frame(width: 17, height: 17)
            .overlay(
                HeartbeatShape()
                    .stroke(.white, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                    // Match the waveform's natural 84:52 bbox aspect so the spike
                    // isn't stretched in the square tile.
                    .frame(width: 13, height: 8)
            )
    }

    private func doRefresh() {
        store.refresh()
        store.refreshQuota(force: true)
        withAnimation(.linear(duration: 0.8)) { refreshSpin += 360 }
    }

    // MARK: Provenance

    private var provenance: some View {
        HStack(spacing: 6) {
            Circle().fill(dc.good).frame(width: 5, height: 5)
            Text("本地实时").font(.system(size: 10)).foregroundStyle(dc.fg3)
            Text("·").font(.system(size: 10)).foregroundStyle(dc.fg3.opacity(0.4))
            Text("额度联网 \(Panel.age(snap.quotaFetchedAt ?? snap.generatedAt, now: snap.generatedAt))")
                .font(.system(size: 10)).foregroundStyle(dc.fg3)
            Spacer()
            Text("\(Panel.clock(snap.generatedAt)) 刷新").font(.system(size: 10)).foregroundStyle(dc.fg3)
        }
        .padding(.horizontal, 13).padding(.top, 7).padding(.bottom, 8)
        .overlay(Rectangle().fill(dc.sep).frame(height: 1), alignment: .top)
    }

    // MARK: Bottom nav

    private var bottomNav: some View {
        HStack(spacing: 0) {
            navButton(0, "总览")
            navButton(1, "构成")
            navButton(2, "洞察")
        }
        .background(dc.navbg)
        .overlay(Rectangle().fill(dc.sep).frame(height: 1), alignment: .top)
    }

    private func navButton(_ i: Int, _ label: String) -> some View {
        Button { tab = i } label: {
            VStack(spacing: 3) {
                NavGlyph(index: i).frame(width: 16, height: 16)
                Text(label).font(.system(size: 9.5, weight: tab == i ? .semibold : .medium))
            }
            .foregroundStyle(tab == i ? dc.accent : dc.fg3)
            .frame(maxWidth: .infinity).padding(.top, 8).padding(.bottom, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).focusEffectDisabled()
    }
}

// Measures the active tab's natural height so the scroll region can size to it
// (up to a screen-based cap).
private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Bottom-nav glyphs (exact SVG geometry from the prototype, 16×16)

private struct NavGlyph: View {
    let index: Int
    var body: some View {
        ZStack {
            switch index {
            case 0:   // 总览 — four 5×5 rounded squares (rx 1.3) in a 2×2 grid
                ForEach(Array([(4.5, 4.5), (11.5, 4.5), (4.5, 11.5), (11.5, 11.5)].enumerated()), id: \.offset) { _, c in
                    RoundedRectangle(cornerRadius: 1.3).frame(width: 5, height: 5).position(x: c.0, y: c.1)
                }
            case 1:   // 构成 — open dashed donut ring (r5.2, stroke 2.4, dash 19 3 7 3, −90°)
                Circle().inset(by: 2.8)
                    .stroke(style: StrokeStyle(lineWidth: 2.4, dash: [19, 3, 7, 3]))
                    .rotationEffect(.degrees(-90))
            default:  // 洞察 — three ascending bars (heights 5 / 8 / 11, width 3, rx 1)
                Group {
                    RoundedRectangle(cornerRadius: 1).frame(width: 3, height: 5).position(x: 3.5, y: 11.5)
                    RoundedRectangle(cornerRadius: 1).frame(width: 3, height: 8).position(x: 8, y: 10)
                    RoundedRectangle(cornerRadius: 1).frame(width: 3, height: 11).position(x: 12.5, y: 8.5)
                }
            }
        }
        .frame(width: 16, height: 16)
    }
}
