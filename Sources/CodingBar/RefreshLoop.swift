import Foundation

// MARK: - Start on the main thread; stop() is idempotent.
@MainActor
final class RefreshLoop {
    private let store: UsageStore
    private var timer: Timer?
    private var quotaTimer: Timer?
    private let interval: TimeInterval
    private let quotaInterval: TimeInterval

    /// `interval` drives the local-log refresh; `quotaInterval` polls the online
    /// quota (the actual network call is gated by QuotaService's 5-min TTL, so a
    /// 60s poll just keeps it fresh without hammering the endpoints).
    init(store: UsageStore, interval: TimeInterval = 30, quotaInterval: TimeInterval = 60) {
        self.store = store
        self.interval = interval
        self.quotaInterval = quotaInterval
    }

    func start() {
        store.refresh()
        store.refreshQuota()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.store.refresh() }
        }
        quotaTimer = Timer.scheduledTimer(withTimeInterval: quotaInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.store.refreshQuota() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        quotaTimer?.invalidate()
        quotaTimer = nil
    }
}
