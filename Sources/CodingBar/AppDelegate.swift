import AppKit
import CodingBarCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: UsageStore!
    private var controller: StatusItemController!
    private var loop: RefreshLoop!

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = UsageStore()
        controller = StatusItemController(store: store)
        loop = RefreshLoop(store: store)
        loop.start()

        // Sparkle's scheduled-check timer starts at SPUStandardUpdaterController init.
        // Touch the singleton at launch (instead of lazily from SettingsView) so a user
        // who flipped on "自动检查更新" once still gets daily checks even when they
        // never reopen Settings again. In dev builds (`swift run`) UpdateManager.init
        // skips Sparkle bootstrap entirely, so this is a no-op there.
        _ = UpdateManager.shared

        // Debug: auto-open the popover for screenshot verification.
        if CommandLine.arguments.contains("--open-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.controller.openPopover()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        loop.stop()
    }
}
