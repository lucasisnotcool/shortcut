import Foundation
import Testing
@testable import AnswerCircle

@Test func comparesVersionsNumerically() {
    #expect(UpdateChecker.isVersion("1.10.0", newerThan: "1.9.2"))
    #expect(UpdateChecker.isVersion("1.0.1", newerThan: "1.0"))
    #expect(!UpdateChecker.isVersion("1.2", newerThan: "1.2.0"))
    #expect(!UpdateChecker.isVersion("0.9.9", newerThan: "1.0.0"))
}

@Test func parsesLatestRelease() throws {
    let json = #"{"tag_name":"v1.2.0","html_url":"https://github.com/o/r/releases/tag/v1.2.0","draft":false,"prerelease":false}"#
    let update = try UpdateChecker.parse(Data(json.utf8), currentVersion: "1.1.0")
    #expect(update == AvailableUpdate(version: "1.2.0", pageURL: URL(string: "https://github.com/o/r/releases/tag/v1.2.0")!))
    #expect(try UpdateChecker.parse(Data(json.utf8), currentVersion: "1.2.0") == nil)
}

@Test func ignoresPrereleases() throws {
    let json = #"{"tag_name":"v9.0.0","html_url":"https://github.com/o/r","prerelease":true}"#
    #expect(try UpdateChecker.parse(Data(json.utf8), currentVersion: "1.0.0") == nil)
}

@Test func migratesLegacyDataOnce() throws {
    let suite = "shortcut-migration-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let legacyFolder = base.appendingPathComponent("AnswerCircle/Conversation", isDirectory: true)
    try FileManager.default.createDirectory(at: legacyFolder, withIntermediateDirectories: true)
    try Data("[]".utf8).write(to: legacyFolder.appendingPathComponent("messages.json"))
    defaults.set(["/tmp/newer"], forKey: "Shortcut.ContextRoots")
    let legacy: [String: Any] = [
        "Shortcut.ContextRoots": ["/tmp/course"], "AnswerCircle.ClaudeSessionStarted": true, "NSUnrelated": 1
    ]

    AppIdentity.migrateLegacyDataIfNeeded(defaults: defaults, legacySettings: legacy, supportBase: base)

    #expect(defaults.stringArray(forKey: "Shortcut.ContextRoots") == ["/tmp/newer"])
    #expect(defaults.bool(forKey: "AnswerCircle.ClaudeSessionStarted"))
    #expect(defaults.object(forKey: "NSUnrelated") == nil)
    #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("Shortcut/Conversation/messages.json").path))
    #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("AnswerCircle").path))

    // A second run changes nothing.
    defaults.removeObject(forKey: "AnswerCircle.ClaudeSessionStarted")
    AppIdentity.migrateLegacyDataIfNeeded(defaults: defaults, legacySettings: legacy, supportBase: base)
    #expect(defaults.object(forKey: "AnswerCircle.ClaudeSessionStarted") == nil)
}
