import Foundation

// MARK: - Drives periodic refresh of UsageStore. Start on the main thread; stop() is idempotent.
@MainActor
final class RefreshLoop {
    private let store: UsageStore
    private var timer: Timer?
    private let interval: TimeInterval

    init(store: UsageStore, interval: TimeInterval = 30) {
        self.store = store
        self.interval = interval
    }

    func start() {
        store.refresh()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.store.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
