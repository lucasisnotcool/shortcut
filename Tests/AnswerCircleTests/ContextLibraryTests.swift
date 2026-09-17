import Foundation
import Testing
@testable import AnswerCircle

@Test func buildsSnapshotFromFolder() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-\(UUID().uuidString)")
    let nested = root.appendingPathComponent("unit 1/notes")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "Mitochondria are the powerhouse.".write(to: nested.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
    try "hidden".write(to: nested.appendingPathComponent(".secret.md"), atomically: true, encoding: .utf8)
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: root.appendingPathComponent("diagram.png"))
    try Data([0, 1, 2, 3]).write(to: root.appendingPathComponent("blob.bin"))
    let notebook = ##"{"cells":[{"cell_type":"markdown","source":["# Title\n","Body"]},{"cell_type":"code","source":"print(1)","outputs":[{"text":["1\n"]},{"data":{"image/png":"AAAA"}}]}]}"##
    try notebook.write(to: root.appendingPathComponent("lab.ipynb"), atomically: true, encoding: .utf8)

    let snapshot = await ContextLibrary.build(roots: [root])
    let byName = Dictionary(uniqueKeysWithValues: snapshot.files.map { ($0.url.lastPathComponent, $0.status) })
    #expect(byName.count == 4)
    #expect(byName[".secret.md"] == nil)
    if case .inline = byName["a.md"] {} else { Issue.record("markdown should be inline") }
    if case .inline = byName["lab.ipynb"] {} else { Issue.record("notebook should be inline") }
    if case .onDemand = byName["diagram.png"] {} else { Issue.record("image should be on demand") }
    if case .unsupported = byName["blob.bin"] {} else { Issue.record("binary should be unsupported") }
    #expect(snapshot.documentsBlock.contains("Mitochondria are the powerhouse."))
    #expect(snapshot.documentsBlock.contains("print(1)"))
    #expect(!snapshot.documentsBlock.contains("AAAA"))
    #expect(snapshot.documentsBlock.contains("<on_demand_files>"))
    #expect(snapshot.fingerprint == ContextLibrary.fingerprint(roots: [root]))
}

/// Prints the readiness report for a real folder when SHORTCUT_CONTEXT_DIR is set.
@Test func reportRealFolder() async {
    guard let path = ProcessInfo.processInfo.environment["SHORTCUT_CONTEXT_DIR"] else { return }
    let start = Date()
    let snapshot = await ContextLibrary.build(roots: [URL(fileURLWithPath: path)])
    for file in snapshot.files { print("CTX \(file.status) \(file.displayPath)") }
    print("CTX total inline tokens ≈ \(snapshot.inlineTokens), files \(snapshot.files.count), built in \(String(format: "%.1f", Date().timeIntervalSince(start)))s, block \(snapshot.documentsBlock.utf8.count) bytes")
}
