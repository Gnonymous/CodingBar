import Foundation
import Sparkle

// MARK: - In-app auto-update (Sparkle 2.x).
//
// PRIVACY: CodingBar reads usage 100% locally; the only other network paths are
// (1) the quota path (user's own OAuth token, user's own data) and now (2) Sparkle's
// appcast pull + update zip download. Sparkle is OPT-IN — default off, the user
// enables it from Settings. When on, Sparkle pulls a small XML feed daily, verifies
// every update against the EdDSA public key baked into Info.plist (SUPublicEDKey),
// and only installs binaries whose signature matches. No auth, no telemetry, no
// local data uploaded.
//
// `UpdateManager.shared` is a thin façade on `SPUStandardUpdaterController`.
// Sparkle's standard user driver supplies the "新版本可用 → 立刻更新" dialog,
// download progress, and restart prompt — we just expose the toggle/button.
@MainActor
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    /// `CFBundleShortVersionString` from the packaged .app (stamped by package.sh);
    /// "dev" when run via `swift run` (no version-bearing bundle).
    static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "dev"
    }

    /// Used by the Settings footer's "GitHub →" link; safe to call even when Sparkle
    /// can't run (dev builds have no Info.plist feed URL).
    static var releasesPageURL: URL { URL(string: "https://github.com/Gnonymous/CodingBar/releases/latest")! }

    /// nil in dev (swift run) — Sparkle refuses to start without a real .app bundle
    /// holding SUFeedURL/SUPublicEDKey. Guard every Sparkle call against this so the
    /// dev workflow stays functional.
    private let controller: SPUStandardUpdaterController?

    /// Whether Sparkle is wired up. False in dev builds; SettingsView surfaces a
    /// disabled control + a hint in that case.
    var canUpdate: Bool { controller != nil }

    /// Bound to the Settings toggle. Sparkle persists this in NSUserDefaults
    /// (`SUEnableAutomaticChecks`), so we don't manage storage ourselves.
    var automaticChecksEnabled: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    @Published private(set) var hasAvailableUpdate = false

    private init() {
        // SPUStandardUpdaterController(startingUpdater: true) crashes if Info.plist
        // lacks SUFeedURL — true for `swift run` dev builds. Detect a real .app
        // bundle by checking the path, NOT by checking Info.plist keys (Sparkle
        // reads its own defaults too late for us to catch the failure).
        if Bundle.main.bundlePath.hasSuffix(".app") {
            let c = SPUStandardUpdaterController(
                startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
            )
            controller = c
            Self.observe(updater: c.updater) { [weak self] in self?.hasAvailableUpdate = $0 }
        } else {
            controller = nil
        }
    }

    /// "立刻检查" button. Sparkle's standard user driver takes over from here —
    /// it shows the version dialog, downloads, validates the EdDSA signature, and
    /// prompts to restart. We just kick it off.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// Light wrapper around the three Sparkle notifications we care about so the
    /// observer block can live in a single place. We don't keep the observer tokens
    /// — NotificationCenter retains the blocks strongly for the app's lifetime, but
    /// the manager is a singleton, so there's nothing to leak from: the controller,
    /// observers and closures all share a single, process-wide lifetime.
    private static func observe(updater: SPUUpdater, _ setHasUpdate: @escaping (Bool) -> Void) {
        let center = NotificationCenter.default
        center.addObserver(forName: NSNotification.Name.SUUpdaterDidFindValidUpdate,
                           object: updater, queue: .main) { _ in setHasUpdate(true) }
        center.addObserver(forName: NSNotification.Name.SUUpdaterDidNotFindUpdate,
                           object: updater, queue: .main) { _ in setHasUpdate(false) }
        center.addObserver(forName: NSNotification.Name.SUUpdaterWillRestart,
                           object: updater, queue: .main) { _ in setHasUpdate(false) }
    }
}

