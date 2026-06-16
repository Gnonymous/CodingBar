import AppKit
import CodingBarCore

// Minimal scaffold delegate so the app builds and shows a menu bar item.
// StatusItemController + UsageStore + the real views replace this body in later phases.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "CodingBar"
        statusItem = item
    }
}
