import AppKit
import Foundation

/// Outcome of an update check / install. Drives the menu bar item and the
/// About pane.
enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case available(version: String)
    case downloading(version: String, fraction: Double)
    case installing(version: String, phase: InstallPhase)
    case failed
    case installFailed(version: String)
}

/// Sub-steps of the in-place install, surfaced so the UI can say "verifying"
/// or "extracting" rather than one opaque "installing".
enum InstallPhase: Equatable {
    case verifying
    case unzipping
    case installing
}

extension Notification.Name {
    static let updateStateDidChange = Notification.Name("capcap.updateStateDidChange")
}

/// Checks GitHub Releases for a newer capcap version and, when asked, downloads
/// and installs it in place.
///
/// The release zip is signed with capcap's reusable self-signed certificate
/// (see release.yml), so an in-place swap keeps a stable code-signing identity
/// and the user's TCC permissions survive the update. `UpdateInstaller` does
/// the download/unzip/swap; this type owns the state machine and the GitHub
/// API parsing.
final class UpdateChecker {
    static let shared = UpdateChecker()

    private let repo = "realskyrin/capcap"
    private let throttleKey = "lastUpdateCheckAt"
    private let skippedVersionKey = "skippedUpdateVersion"
    private let shortcutTriggerDayKey = "automaticUpdateCheckShortcutTriggerDay"
    private let shortcutTriggerCountKey = "automaticUpdateCheckShortcutTriggerCount"
    private let automaticCheckShortcutTriggerCount = 1

    private(set) var state: UpdateState = .idle {
        didSet {
            NotificationCenter.default.post(name: .updateStateDidChange, object: nil)
        }
    }

    /// Details of the latest release, populated by a successful check. Kept
    /// outside `UpdateState` so the enum stays trivially `Equatable`.
    private(set) var latestVersion: String?
    private(set) var latestZipURL: URL?
    private(set) var latestSHA256URL: URL?
    private(set) var latestPageURL: URL?

    private init() {}

    /// Running app version, e.g. "1.1.2".
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// The version the user chose to skip, if any.
    var skippedVersion: String? {
        UserDefaults.standard.string(forKey: skippedVersionKey)
    }

    /// True while a check or install is in flight — used to reject overlapping
    /// requests.
    private var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    /// Silent automatic check tied to real usage rather than app launch. The
    /// first screenshot-shortcut trigger of each local day checks GitHub unless
    /// a check already ran today.
    func checkFromScreenshotShortcutIfDue() {
        let today = Self.dayKey(for: Date())
        let defaults = UserDefaults.standard
        var triggerCount = defaults.integer(forKey: shortcutTriggerCountKey)

        if defaults.string(forKey: shortcutTriggerDayKey) != today {
            defaults.set(today, forKey: shortcutTriggerDayKey)
            triggerCount = 0
        }

        triggerCount += 1
        defaults.set(triggerCount, forKey: shortcutTriggerCountKey)

        guard triggerCount == automaticCheckShortcutTriggerCount,
              !hasCheckedToday,
              !isBusy
        else { return }

        check(manual: false)
    }

    private var hasCheckedToday: Bool {
        guard let last = UserDefaults.standard.object(forKey: throttleKey) as? Date else {
            return false
        }
        return Calendar.autoupdatingCurrent.isDateInToday(last)
    }

    /// Performs a check. `completion` fires on the main thread with the final
    /// state. Manual checks ignore the screenshot-shortcut gate and the
    /// skipped-version preference; a background check stays silent about a
    /// skipped version.
    func check(manual: Bool, completion: ((UpdateState) -> Void)? = nil) {
        guard !isBusy else {
            completion?(state)
            return
        }
        setState(.checking)

        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            finish(.failed, completion: completion)
            return
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub rejects API requests that arrive without a User-Agent.
        request.setValue("capcap/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let self = self else { return }

            // Record the attempt regardless of outcome so a failing network
            // doesn't retry on every screenshot shortcut trigger today.
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
            let assets = json["assets"] as? [[String: Any]] ?? []
            let pageURL = (json["html_url"] as? String).flatMap(URL.init)
                ?? URL(string: "https://github.com/\(self.repo)/releases/latest")!

            guard Self.isVersion(latest, newerThan: self.currentVersion) else {
                self.finish(.upToDate, completion: completion)
                return
            }

            self.latestVersion = latest
            self.latestPageURL = pageURL
            self.latestZipURL = Self.assetURL(in: assets) { $0.hasSuffix(".zip") }
            self.latestSHA256URL = Self.assetURL(in: assets) { $0.hasSuffix(".zip.sha256") }

            // A background check stays quiet about a version the user skipped;
            // a manual check always reports it.
            if !manual, latest == self.skippedVersion {
                self.finish(.upToDate, completion: completion)
            } else {
                self.finish(.available(version: latest), completion: completion)
            }
        }.resume()
    }

    /// Marks the latest release as skipped so future background checks ignore
    /// it, and resets the UI to the up-to-date state.
    func skipVersion() {
        guard let version = latestVersion else { return }
        UserDefaults.standard.set(version, forKey: skippedVersionKey)
        setState(.upToDate)
    }

    /// Downloads the latest release, verifies it, installs it in place of the
    /// running app, and relaunches. `onFailure` fires on the main thread if any
    /// step fails — the running app is left untouched. On success the app
    /// terminates and the detached helper reopens the new build.
    func downloadAndInstall(onFailure: (() -> Void)? = nil) {
        guard case .available(let version) = state else { return }

        // No installable asset (e.g. a release still publishing) — fall back to
        // the release page so the user can grab it manually.
        guard let zipURL = latestZipURL else {
            if let page = latestPageURL { NSWorkspace.shared.open(page) }
            return
        }

        // Clear anything an earlier interrupted update left behind so temp
        // artifacts never pile up across runs.
        UpdateInstaller.cleanStaleArtifacts()

        setState(.downloading(version: version, fraction: 0))

        let fail: () -> Void = { [weak self] in
            self?.setState(.installFailed(version: version))
            onFailure?()
        }

        fetchExpectedHash { [weak self] expectedHash in
            guard let self = self else { return }
            var lastPercent = -1
            UpdateInstaller.shared.downloadZip(
                from: zipURL,
                progress: { fraction in
                    // Throttle to whole-percent steps so the menu/About pane
                    // don't rebuild on every byte.
                    let percent = Int(fraction * 100)
                    guard percent != lastPercent else { return }
                    lastPercent = percent
                    self.setState(.downloading(version: version, fraction: fraction))
                },
                completion: { result in
                    switch result {
                    case .failure:
                        fail()
                    case .success(let zipPath):
                        self.setState(.installing(version: version, phase: .verifying))
                        DispatchQueue.global(qos: .userInitiated).async {
                            do {
                                try UpdateInstaller.install(
                                    zipAt: zipPath,
                                    expectedSHA256: expectedHash,
                                    phase: { phase in
                                        self.setState(.installing(version: version,
                                                                  phase: phase))
                                    }
                                )
                                DispatchQueue.main.async { NSApp.terminate(nil) }
                            } catch {
                                DispatchQueue.main.async { fail() }
                            }
                        }
                    }
                }
            )
        }
    }

    /// Fetches the `.sha256` companion asset so the download can be verified.
    /// Best-effort: a missing or unreadable checksum yields nil and the install
    /// proceeds without verification rather than failing outright.
    private func fetchExpectedHash(_ completion: @escaping (String?) -> Void) {
        guard let url = latestSHA256URL else {
            completion(nil)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("capcap/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data = data,
                  let text = String(data: data, encoding: .utf8)
            else {
                completion(nil)
                return
            }
            // The file holds "<hash>  <filename>"; take the first token.
            let hash = text.split(whereSeparator: { " \t\n".contains($0) }).first
            completion(hash.map(String.init))
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

    /// Returns the download URL of the first release asset whose name matches.
    private static func assetURL(
        in assets: [[String: Any]],
        where matches: (String) -> Bool
    ) -> URL? {
        for asset in assets {
            guard let name = asset["name"] as? String, matches(name),
                  let urlString = asset["browser_download_url"] as? String,
                  let url = URL(string: urlString)
            else { continue }
            return url
        }
        return nil
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

    private static func dayKey(for date: Date) -> String {
        let components = Calendar.autoupdatingCurrent.dateComponents([.year, .month, .day], from: date)
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }

    private static func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
    }
}
