import Foundation

// MARK: - User-initiated update check.
//
// PRIVACY: CodingBar reads usage 100% locally; the only other network access is the
// quota path. This adds ONE more, strictly user-initiated, read-only GET to the public
// GitHub Releases API (no auth, no local data sent) — fired only when the user taps
// "检查更新" in Settings. Never automatic, never telemetry.
enum UpdateChecker {
    static let repo = "Gnonymous/CodingBar"

    /// `CFBundleShortVersionString` from the packaged .app (stamped by package.sh);
    /// "dev" when run via `swift run` (no version-bearing bundle).
    static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "dev"
    }

    static var releasesPageURL: URL { URL(string: "https://github.com/\(repo)/releases/latest")! }

    enum Result: Equatable {
        case upToDate(String)        // current == latest
        case updateAvailable(String) // latest tag, newer than current
        case failed
    }

    static func check() async -> Result {
        guard let api = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return .failed }
        var req = URLRequest(url: api, timeoutInterval: 10)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = (obj["tag_name"] as? String)?.trimmingCharacters(in: .whitespaces), !tag.isEmpty
        else { return .failed }

        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let current = currentVersion
        // A dev build has no real version to compare against — just point at the latest.
        if current == "dev" { return .updateAvailable(latest) }
        return isNewer(latest, than: current) ? .updateAvailable(latest) : .upToDate(current)
    }

    /// Numeric dotted-version compare ("1.10.0" > "1.9.0"). Non-numeric chars in a
    /// component are stripped; missing components count as 0.
    static func isNewer(_ latest: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 } }
        let a = parts(latest), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
