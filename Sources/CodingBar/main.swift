import AppKit
import CodingBarCore

/// Bridges the async QuotaService to this synchronous CLI entry point. The Task
/// runs on the cooperative pool (network I/O off the main thread) while the
/// semaphore blocks; no deadlock because the actor/URLSession never need main.
/// Keeps top-level code synchronous so AppKit's `app.run()` and `assumeIsolated`
/// stay valid for the GUI path.
final class QuotaBox: @unchecked Sendable { var windows: [QuotaWindow] = []; var notes: [String] = [] }
func fetchQuotaBlocking() -> QuotaBox {
    let box = QuotaBox()
    let sem = DispatchSemaphore(value: 0)
    Task { let r = await QuotaService.shared.current(); box.windows = r.windows; box.notes = r.notes; sem.signal() }
    sem.wait()
    return box
}

// Headless mode: print the computed snapshot as JSON and exit. Lets us verify the
// data layer against real local logs without launching the GUI.
if CommandLine.arguments.contains("--dump-json") {
    // Fetch live quota (Claude + Codex usage APIs) then aggregate local data.
    // The snapshot carries all three overview ranges (today / week / month).
    let quota = fetchQuotaBlocking()
    var snap = Aggregator.run(quota: quota.windows)
    snap.quotaNotes = quota.notes
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    enc.dateEncodingStrategy = .iso8601
    if let data = try? enc.encode(snap), let s = String(data: data, encoding: .utf8) {
        print(s)
    }
    exit(0)
}

if CommandLine.arguments.contains("--self-test") {
    exit(Int32(SelfTest.run()))
}

// Debug: rasterize UI components to a PNG (display-independent verification).
if let i = CommandLine.arguments.firstIndex(of: "--render-menubar"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    let path = CommandLine.arguments[i + 1]
    MainActor.assumeIsolated { RenderDebug.renderMenuBar(to: path) }
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--render-panel"), i + 2 < CommandLine.arguments.count {
    _ = NSApplication.shared
    let args = CommandLine.arguments
    let path = args[i + 1]
    let tab = Int(args[i + 2]) ?? 0
    // Optional: --render-panel <path> <tab> [light|dark] [healthy|degraded|nosession|empty]
    let dark = (i + 3 < args.count) ? (args[i + 3].lowercased() != "light") : true
    let scenario = (i + 4 < args.count) ? args[i + 4] : "healthy"
    MainActor.assumeIsolated { RenderDebug.renderPanel(to: path, tab: tab, dark: dark, scenario: scenario) }
    exit(0)
}

// GUI mode: a background (accessory) menu bar app.
// Single instance: terminate any older copies of ourselves so repackage/relaunch
// cycles can't leave duplicate menu-bar icons behind.
if let bid = Bundle.main.bundleIdentifier {
    for other in NSRunningApplication.runningApplications(withBundleIdentifier: bid)
    where other != NSRunningApplication.current {
        other.terminate()
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
