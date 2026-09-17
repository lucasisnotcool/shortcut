import Foundation

struct AvailableUpdate: Equatable {
    let version: String
    let pageURL: URL
}

/// Compares the running version with the latest GitHub release. Only the
/// public releases API is contacted; nothing about the user is sent.
enum UpdateChecker {
    private static let lastCheckKey = "Shortcut.LastUpdateCheck"
    static let automaticKey = "Shortcut.CheckForUpdates"
    private static let interval: TimeInterval = 24 * 60 * 60

    static var checksAutomatically: Bool {
        get { UserDefaults.standard.object(forKey: automaticKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: automaticKey) }
    }

    private static let announcedKey = "Shortcut.AnnouncedUpdate"

    /// Automatic checks announce each new version once; the banner stays.
    static func hasAnnounced(_ update: AvailableUpdate) -> Bool {
        UserDefaults.standard.string(forKey: announcedKey) == update.version
    }

    static func markAnnounced(_ update: AvailableUpdate) {
        UserDefaults.standard.set(update.version, forKey: announcedKey)
    }

    static var isDue: Bool {
        guard checksAutomatically else { return false }
        let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast
        return Date().timeIntervalSince(last) >= interval
    }

    /// The newer release, or nil when this version is current.
    static func latest(currentVersion: String = AppIdentity.version) async throws -> AvailableUpdate? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(AppIdentity.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Shortcut/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        // Recorded up front so an offline Mac doesn't retry on every activation.
        UserDefaults.standard.set(Date(), forKey: lastCheckKey)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AppError.processFailed("GitHub returned status \((response as? HTTPURLResponse)?.statusCode ?? 0).")
        }
        return try parse(data, currentVersion: currentVersion)
    }

    static func parse(_ data: Data, currentVersion: String) throws -> AvailableUpdate? {
        struct Release: Decodable {
            let tag_name: String
            let html_url: URL
            let draft: Bool?
            let prerelease: Bool?
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard release.draft != true, release.prerelease != true else { return nil }
        let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        guard isVersion(version, newerThan: currentVersion) else { return nil }
        return AvailableUpdate(version: version, pageURL: release.html_url)
    }

    /// Numeric dotted comparison: 1.10.0 > 1.9.2, 1.2 == 1.2.0.
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        func parts(_ value: String) -> [Int] {
            value.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}
