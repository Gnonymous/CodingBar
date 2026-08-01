import AppKit
import Combine
import SwiftUI
import CodingBarCore

// MARK: -
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let store: UsageStore
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var pulse: PulseLayerView!
    private var menuWatch: AnyCancellable?

    init(store: UsageStore) {
        self.store = store
        super.init()
        setupStatusItem()
        setupPopover()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }

        // The pulse is AppKit + CALayer, the readout stays SwiftUI. Keeping the animated
        // glyph out of the NSHostingView is the whole point: a SwiftUI animation in here
        // re-lays-out the status item every frame. See PulseLayerView for the numbers.
        let pulse = PulseLayerView()
        self.pulse = pulse
        pulse.translatesAutoresizingMaskIntoConstraints = false

        // Concrete root type, not AnyView: type erasure defeats SwiftUI's structural
        // diffing, so every publish rebuilt the item's tree instead of updating it.
        let readout = NSHostingView(rootView: StatusItemContentView(store: store))
        readout.translatesAutoresizingMaskIntoConstraints = false

        button.addSubview(pulse)
        button.addSubview(readout)
        // Auto Layout still drives the item's width (true variableLength) — but now only
        // the readout's text can change it, and that happens on the 30s refresh, not per frame.
        NSLayoutConstraint.activate([
            pulse.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 4),
            pulse.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            pulse.widthAnchor.constraint(equalToConstant: PulseLayerView.box.width),
            pulse.heightAnchor.constraint(equalToConstant: PulseLayerView.box.height),
            readout.leadingAnchor.constraint(equalTo: pulse.trailingAnchor, constant: 6),
            readout.topAnchor.constraint(equalTo: button.topAnchor),
            readout.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            readout.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -4),
        ])
        button.action = #selector(handleClick(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        // objectWillChange fires *before* the value lands, so hop a runloop turn to read
        // the settled snapshot.
        syncPulse()
        menuWatch = store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.syncPulse() }
    }

    private func syncPulse() {
        let m = store.snapshot.menu
        pulse.update(active: m.active, throughput: m.throughput)
    }

    /// Left-click toggles the popover; right-click (or ⌃-click) shows a small menu
    /// with the affordances the v3 panel intentionally omits (metric toggle, quit).
    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRight = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)
        if isRight { showContextMenu(from: sender) } else { togglePopover(sender) }
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        let lang = store.language
        let menu = NSMenu()
        let metricTitle = store.menuMetric == .tokens
            ? lang.t("Menu bar: today's cost", "菜单栏显示：今日花费")
            : lang.t("Menu bar: today's tokens", "菜单栏显示：今日 Token")
        let metric = NSMenuItem(title: metricTitle, action: #selector(toggleMetric), keyEquivalent: "")
        metric.target = self
        menu.addItem(metric)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: lang.t("Quit CodingBar", "退出 CodingBar"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
    }

    @objc private func toggleMetric() { store.toggleMetric() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func setupPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let host = NSHostingController(rootView: PanelView(store: store))
        // Let the popover size itself to the SwiftUI content, and resize when the
        // active tab changes height (no fixed/clipped panel).
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown { popover.performClose(sender) } else { openPopover() }
    }

    /// Open the popover programmatically (also used by --open-panel).
    func openPopover() {
        guard !popover.isShown, let button = statusItem.button else { return }
        store.refresh()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}

// MARK: -
// Readout only — the glyph is a sibling AppKit view, not part of this tree.
private struct StatusItemContentView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        let s = store.snapshot.menu
        let menu = MenuSummary(metric: store.menuMetric, primaryText: store.primaryText,
                               quotaPercent: s.quotaPercent, active: s.active, throughput: s.throughput)
        MenuBarReadout(menu: menu)
            .frame(height: 22)
            .fixedSize()
    }
}
