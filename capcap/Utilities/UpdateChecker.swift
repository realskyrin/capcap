import Foundation

/// Outcome of an update check. Drives the menu bar item and the About pane.
enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case available(version: String, url: URL)
    case failed
}

extension Notification.Name {
    static let updateStateDidChange = Notification.Name("capcap.updateStateDidChange")
}

/// Checks GitHub Releases for a newer capcap version.
///
/// Notify-only by design: capcap ships unsigned (see release.yml), so it never
/// downloads or installs an update itself — it points the user at the GitHub
/// release page and lets them (or Homebrew) take it from there.
final class UpdateChecker {
    static let shared = UpdateChecker()

    private let repo = "realskyrin/capcap"
    private let throttleKey = "lastUpdateCheckAt"
    private let throttleInterval: TimeInterval = 24 * 60 * 60

    private(set) var state: UpdateState = .idle {
        didSet {
            NotificationCenter.default.post(name: .updateStateDidChange, object: nil)
        }
    }

    private init() {}

    /// Running app version, e.g. "1.1.2".
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Background check fired on launch. Skipped if a check already ran within
    /// the last 24h so an app that launches often doesn't hammer the API.
    func checkOnLaunchIfDue() {
        if let last = UserDefaults.standard.object(forKey: throttleKey) as? Date,
           Date().timeIntervalSince(last) < throttleInterval {
            return
        }
        check(manual: false)
    }

    /// Performs a check. `completion` fires on the main thread with the final
    /// state. Manual checks ignore the 24h throttle.
    func check(manual: Bool, completion: ((UpdateState) -> Void)? = nil) {
        guard state != .checking else {
            completion?(state)
            return
        }
        setState(.checking)

        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            finish(.failed, completion: completion)
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub rejects API requests that arrive without a User-Agent.
        request.setValue("capcap/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let self = self else { return }

            // Record the attempt regardless of outcome so a failing network
            // doesn't retry on every launch.
            UserDefaults.standard.set(Date(), forKey: self.throttleKey)

            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String
            else {
                self.finish(.failed, completion: completion)
                return
            }

            let latest = Self.normalizeVersion(tag)
            let pageURL = (json["html_url"] as? String).flatMap(URL.init)
                ?? URL(string: "https://github.com/\(self.repo)/releases/latest")!

            if Self.isVersion(latest, newerThan: self.currentVersion) {
                self.finish(.available(version: latest, url: pageURL), completion: completion)
            } else {
                self.finish(.upToDate, completion: completion)
            }
        }.resume()
    }

    private func finish(_ newState: UpdateState, completion: ((UpdateState) -> Void)?) {
        DispatchQueue.main.async {
            self.state = newState
            completion?(newState)
        }
    }

    private func setState(_ newState: UpdateState) {
        if Thread.isMainThread {
            state = newState
        } else {
            DispatchQueue.main.async { self.state = newState }
        }
    }

    /// Strips a leading `release-v` / `v` from a tag — capcap tags releases as
    /// `release-v1.1.2`, so "release-v1.1.2" becomes "1.1.2".
    static func normalizeVersion(_ raw: String) -> String {
        var v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.hasPrefix("release-v") {
            v.removeFirst("release-v".count)
        } else if v.hasPrefix("release-") {
            v.removeFirst("release-".count)
        }
        if v.hasPrefix("v") || v.hasPrefix("V") {
            v.removeFirst()
        }
        return v
    }

    /// Component-wise numeric comparison: "1.2.0" is newer than "1.1.9".
    static func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        let a = components(lhs)
        let b = components(rhs)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
    }
}
