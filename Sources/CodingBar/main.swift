import AppKit
import CodingBarCore

// Headless mode: print the computed snapshot as JSON and exit. Lets us verify the
// data layer against real local logs without launching the GUI.
if CommandLine.arguments.contains("--dump-json") {
    let snap = Aggregator.run()   // was: Snapshot.sample()
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    enc.dateEncodingStrategy = .iso8601
    if let data = try? enc.encode(snap), let s = String(data: data, encoding: .utf8) {
        print(s)
    }
    exit(0)
}

// GUI mode: a background (accessory) menu bar app.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
