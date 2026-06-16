import AppKit
import SwiftUI
import CodingBarCore

// MARK: - Owns the NSStatusItem (hosting MenuBarItemView) and the NSPopover.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let store: UsageStore
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!

    init(store: UsageStore) {
        self.store = store
        super.init()
        setupStatusItem()
        setupPopover()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }

        // Host the SwiftUI item and let Auto Layout drive the status item's width (true variableLength).
        let hosting = NSHostingView(rootView: AnyView(StatusItemContentView(store: store)))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: button.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 4),
            hosting.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -4),
        ])
        button.action = #selector(togglePopover(_:))
        button.target = self
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PanelView(store: store))
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

// MARK: - SwiftUI wrapper that re-reads the store and rebuilds the MenuSummary on each change.
private struct StatusItemContentView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        let s = store.snapshot.menu
        let menu = MenuSummary(metric: store.menuMetric, primaryText: store.primaryText,
                               quotaPercent: s.quotaPercent, active: s.active, throughput: s.throughput)
        MenuBarItemView(menu: menu)
    }
}
