import Foundation

/// Names and locations that identify the app, plus the one-time move from the
/// pre-release identity (`local.lohzh.AnswerCircle`, "AnswerCircle" folder).
enum AppIdentity {
    static let bundleID = "io.github.lucasisnotcool.shortcut"
    static let repository = "lucasisnotcool/shortcut"
    static let repositoryURL = URL(string: "https://github.com/\(repository)")!
    static let legacyBundleID = "local.lohzh.AnswerCircle"
    private static let supportFolderName = "Shortcut"
    private static let legacySupportFolderName = "AnswerCircle"
    private static let migratedKey = "Shortcut.MigratedFromLegacyIdentity"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// `~/Library/Application Support/Shortcut`, created on demand.
    static func supportDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let url = base.appendingPathComponent(supportFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Copies settings and moves saved data from the old identity. Runs once,
    /// before anything reads defaults. The Claude workspace moves with the
    /// folder, so the old session is not found and a new one starts on the
    /// next request; the saved chat stays visible.
    static func migrateLegacyDataIfNeeded(
        defaults: UserDefaults = .standard,
        legacySettings: [String: Any]? = UserDefaults.standard.persistentDomain(forName: legacyBundleID),
        supportBase: URL? = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                        appropriateFor: nil, create: false)
    ) {
        guard !defaults.bool(forKey: migratedKey) else { return }
        defaults.set(true, forKey: migratedKey)

        if let legacy = legacySettings {
            let keys = legacy.keys.filter { $0.hasPrefix("Shortcut.") || $0.hasPrefix("AnswerCircle.") }
            for key in keys where defaults.object(forKey: key) == nil {
                defaults.set(legacy[key], forKey: key)
            }
            appLog.notice("Copied \(keys.count) settings from \(legacyBundleID, privacy: .public)")
        }

        let fileManager = FileManager.default
        guard let base = supportBase else { return }
        let legacyFolder = base.appendingPathComponent(legacySupportFolderName, isDirectory: true)
        let folder = base.appendingPathComponent(supportFolderName, isDirectory: true)
        guard fileManager.fileExists(atPath: legacyFolder.path), !fileManager.fileExists(atPath: folder.path) else { return }
        do {
            try fileManager.moveItem(at: legacyFolder, to: folder)
            appLog.notice("Moved saved data to \(folder.path, privacy: .public)")
        } catch {
            appLog.error("Could not move saved data: \(error.localizedDescription, privacy: .public)")
        }
    }
}
