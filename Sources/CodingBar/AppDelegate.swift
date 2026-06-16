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
