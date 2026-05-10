import AppKit
import Foundation

/// GitHub Release-based update checker for Wavetty.
///
/// Sparkle is disabled in Wavetty (the upstream appcast does not list our
/// fork's releases). This checker polls the GitHub Releases API and shows
/// an alert when a newer version is available.
///
/// - On launch: silent check (only shows UI if newer version found, throttled
///   to once per `checkInterval`).
/// - Manual: `checkManually()` always shows UI.
@MainActor
enum WavettyUpdateChecker {
    private static let releaseAPI = URL(string: "https://api.github.com/repos/withwave/ghostty/releases/latest")!
    private static let releasesPage = URL(string: "https://github.com/withwave/ghostty/releases")!
    private static let lastCheckKey = "WavettyLastUpdateCheck"
    private static let skipVersionKey = "WavettySkippedVersion"
    private static let checkInterval: TimeInterval = 60 * 60 * 24

    static func checkOnLaunch() {
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        let now = Date().timeIntervalSince1970
        guard now - last > checkInterval else { return }
        Task { await check(showWhenUpToDate: false) }
    }

    static func checkManually() {
        Task { await check(showWhenUpToDate: true) }
    }

    private static func check(showWhenUpToDate: Bool) async {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)

        do {
            var request = URLRequest(url: releaseAPI)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                if showWhenUpToDate { showError("Cannot reach GitHub.") }
                return
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                if showWhenUpToDate { showError("Cannot parse release info.") }
                return
            }

            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

            if compare(latest, current) == .orderedDescending {
                if !showWhenUpToDate, UserDefaults.standard.string(forKey: skipVersionKey) == latest { return }
                showAvailable(latest: latest, current: current)
            } else if showWhenUpToDate {
                showUpToDate(current: current)
            }
        } catch {
            if showWhenUpToDate { showError(error.localizedDescription) }
        }
    }

    private static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let parts: (String) -> [Int] = { v in
            (v.split(separator: "-").first.map(String.init) ?? "")
                .split(separator: ".")
                .compactMap { Int($0) }
        }
        let aa = parts(a), bb = parts(b)
        for i in 0..<max(aa.count, bb.count) {
            let av = i < aa.count ? aa[i] : 0
            let bv = i < bb.count ? bb[i] : 0
            if av < bv { return .orderedAscending }
            if av > bv { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func showAvailable(latest: String, current: String) {
        let alert = NSAlert()
        alert.messageText = "Wavetty Update Available"
        alert.informativeText = "Wavetty \(latest) is available. You have \(current)."
        alert.addButton(withTitle: "View Release")
        alert.addButton(withTitle: "Skip This Version")
        alert.addButton(withTitle: "Later")
        alert.alertStyle = .informational
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(releasesPage)
        case .alertSecondButtonReturn:
            UserDefaults.standard.set(latest, forKey: skipVersionKey)
        default:
            break
        }
    }

    private static func showUpToDate(current: String) {
        let alert = NSAlert()
        alert.messageText = "You're up to date!"
        alert.informativeText = "Wavetty \(current) is the latest version."
        alert.alertStyle = .informational
        alert.runModal()
    }

    private static func showError(_ msg: String) {
        let alert = NSAlert()
        alert.messageText = "Update Check Failed"
        alert.informativeText = msg
        alert.alertStyle = .warning
        alert.runModal()
    }
}
