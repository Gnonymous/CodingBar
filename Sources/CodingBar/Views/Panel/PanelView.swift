import SwiftUI
import AppKit
import CodingBarCore

// MARK: - The full popover panel: header + 3 tabs + footer (per mockups/panel-02.html)
struct PanelView: View {
    @ObservedObject var store: UsageStore
    @State private var tab: Int
    let scrollable: Bool
    var onQuit: () -> Void

    init(store: UsageStore, initialTab: Int = 0, scrollable: Bool = true,
         onQuit: @escaping () -> Void = { NSApplication.shared.terminate(nil) }) {
        self.store = store
        self._tab = State(initialValue: initialTab)
        self.scrollable = scrollable
        self.onQuit = onQuit
    }

    private let tabs = ["总览", "习惯", "项目"]
    private var snap: Snapshot { store.snapshot }

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case 1: HabitsTab(snap: snap)
        case 2: ProjectsTab(snap: snap)
        default: OverviewTab(snap: snap)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            PanelDivider()
            // Natural height: the popover sizes itself to whichever tab is active
            // (NSHostingController .preferredContentSize), so every tab shows in
            // full and the panel re-sizes when you switch tabs.
            tabContent
            footer
        }
        .frame(width: Panel.width)
        .background(background)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack {
            HStack(spacing: 7) {
                PulseIcon(active: snap.menu.active, throughput: snap.menu.throughput)
                    .frame(width: 15, height: 14).foregroundStyle(Theme.primaryText)
                Text("CodingBar").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.primaryText)
            }
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(snap.menu.active ? Theme.quotaGreen : Theme.faintText).frame(width: 6, height: 6)
                Text(statusText).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.faintText)
            }
        }
        .padding(.horizontal, Panel.hPad).padding(.top, 13).padding(.bottom, 11)
    }

    private var statusText: String {
        guard snap.menu.active else { return "idle" }
        let t = snap.menu.throughput
        let rate = t >= 1000 ? String(format: "%.1fk", t / 1000) : String(format: "%.0f", t)
        return "writing · \(rate) tok/s"
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { i, t in
                Button { tab = i } label: {
                    Text(t).font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(i == tab ? Theme.primaryText : Theme.dimText)
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                        .background(i == tab
                            ? AnyView(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.08))
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.hairline, lineWidth: 1)))
                            : AnyView(Color.clear))
                        .contentShape(Rectangle())   // whole pill is tappable, not just the glyphs
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()                // no blue macOS focus ring left behind
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.black.opacity(0.18)))
        .padding(.horizontal, Panel.hPad).padding(.top, 12).padding(.bottom, 12)
    }

    private var footer: some View {
        HStack {
            Text("刷新于 \(Panel.relative(snap.generatedAt))")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.faintText)
            Spacer()
            HStack(spacing: 14) {
                footerButton("arrow.clockwise") { store.refresh(); store.refreshQuota(force: true) }
                footerButton("textformat.123") { store.toggleMetric() }
                footerButton("power") { onQuit() }
            }
        }
        .padding(.horizontal, Panel.hPad).padding(.vertical, 10)
        .background(Color.black.opacity(0.18))
        .overlay(Rectangle().fill(Theme.hairline).frame(height: 1), alignment: .top)
    }
    private func footerButton(_ name: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 13)).foregroundStyle(Theme.dimText)
        }
        .buttonStyle(.plain)
    }

    private var background: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(colors: [Theme.brandAmber.opacity(0.06), .clear],
                           startPoint: .topTrailing, endPoint: .center)
        }
    }
}
