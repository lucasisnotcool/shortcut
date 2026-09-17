import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// How a reference file reaches Claude.
enum ContextFileStatus: Equatable {
    /// Text is embedded in the cached system prompt.
    case inline(tokens: Int)
    /// Listed for Claude to open with Read when needed (images, scans, overflow).
    case onDemand(reason: String)
    case unsupported(reason: String)
    case failed(reason: String)

    var isAvailable: Bool {
        switch self {
        case .inline, .onDemand: return true
        case .unsupported, .failed: return false
        }
    }
}

struct ContextFile: Identifiable, Equatable {
    let url: URL
    let displayPath: String
    let byteSize: Int
    var status: ContextFileStatus
    var id: String { url.path }
    /// Canvas downloads keep URL escapes in their names (`%23` for `#`).
    var name: String { url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent }
}

/// Everything a request needs to know about the reference material.
struct ContextSnapshot: Equatable {
    var roots: [URL] = []
    var files: [ContextFile] = []
    /// `<documents>` block for the system prompt; stable for identical inputs
    /// so the prompt cache survives relaunches.
    var documentsBlock = ""
    /// Files Claude may open with Read.
    var onDemandFiles: [URL] = []
    /// mtime/size fingerprint used to skip rebuilding unchanged folders.
    var fingerprint = ""

    var inlineTokens: Int {
        files.reduce(0) { total, file in
            if case .inline(let tokens) = file.status { return total + tokens }
            return total
        }
    }

    var readableDirectories: [String] {
        Array(Set(roots.map { root in
            (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                ? root.path : root.deletingLastPathComponent().path
        } + onDemandFiles.map { $0.deletingLastPathComponent().path })).sorted()
    }
}

enum ContextLibrary {
    /// Anthropic's guidance: under ~200k tokens, include the whole knowledge
    /// base in the prompt instead of retrieving it.
    static let inlineTokenBudget = 200_000
    static let maxFilesScanned = 2_000
    private static let maxTextBytes = 8_000_000

    private static let visionTypes: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]
    private static let richTextTypes: Set<String> = ["docx", "doc", "rtf", "rtfd", "odt", "html", "htm", "webarchive", "wordml"]
    private static let exportHint = "export as PDF or CSV to include"
    private static let unsupportedTypes: [String: String] = [
        "xlsx": exportHint, "xls": exportHint, "numbers": exportHint,
        "key": exportHint, "pages": exportHint, "ppt": "save as .pptx or PDF to include"
    ]

    /// Cheap stat-only pass: changes whenever a file is added, removed or edited.
    static func fingerprint(roots: [URL]) -> String {
        enumerate(roots: roots).map { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            return "\(url.path)|\(values?.fileSize ?? 0)|\(Int(modified))"
        }.joined(separator: "\n")
    }

    static func build(roots: [URL]) async -> ContextSnapshot {
        let urls = enumerate(roots: roots)
        var files: [ContextFile] = []
        var documents: [(file: ContextFile, text: String)] = []
        var onDemand: [URL] = []
        var usedTokens = 0

        for url in urls {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            var file = ContextFile(url: url, displayPath: displayPath(for: url, roots: roots), byteSize: size, status: .failed(reason: ""))
            switch await extract(url) {
            case .text(let text):
                let tokens = estimateTokens(text)
                if usedTokens + tokens <= inlineTokenBudget {
                    usedTokens += tokens
                    file.status = .inline(tokens: tokens)
                    documents.append((file, text))
                } else if Self.readableByClaude(url) {
                    file.status = .onDemand(reason: "over the in-context budget")
                    onDemand.append(url)
                } else {
                    file.status = .unsupported(reason: "over the in-context budget")
                }
            case .vision(let reason):
                file.status = .onDemand(reason: reason)
                onDemand.append(url)
            case .unsupported(let reason):
                file.status = .unsupported(reason: reason)
            case .failed(let reason):
                file.status = .failed(reason: reason)
            }
            files.append(file)
        }

        var snapshot = ContextSnapshot(roots: roots, files: files, onDemandFiles: onDemand)
        snapshot.documentsBlock = documentsBlock(documents, onDemand: onDemand, roots: roots)
        snapshot.fingerprint = fingerprint(roots: roots)
        return snapshot
    }

    // MARK: Enumeration

    static func enumerate(roots: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for root in roots {
            let values = try? root.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if values?.isDirectory == true, values?.isPackage != true {
                guard let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }
                for case let url as URL in enumerator {
                    guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                    let path = url.standardizedFileURL.path
                    if seen.insert(path).inserted { result.append(url.standardizedFileURL) }
                    if result.count >= maxFilesScanned { break }
                }
            } else if FileManager.default.fileExists(atPath: root.path) {
                if seen.insert(root.standardizedFileURL.path).inserted { result.append(root.standardizedFileURL) }
            }
        }
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func displayPath(for url: URL, roots: [URL]) -> String {
        for root in roots where url.path.hasPrefix(root.path + "/") {
            return root.lastPathComponent + "/" + String(url.path.dropFirst(root.path.count + 1))
        }
        return url.lastPathComponent
    }

    // MARK: Extraction

    private enum Extraction {
        case text(String)
        case vision(String)
        case unsupported(String)
        case failed(String)
    }

    private static func readableByClaude(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "pdf" || visionTypes.contains(ext) || isPlainText(url)
    }

    private static func isPlainText(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .text) && !type.conforms(to: .rtf) && !type.conforms(to: .html)
    }

    private static func extract(_ url: URL) async -> Extraction {
        let ext = url.pathExtension.lowercased()
        if let hint = unsupportedTypes[ext] { return .unsupported(hint) }
        if visionTypes.contains(ext) { return .vision("image, read on demand") }
        if ext == "heic" || ext == "tiff" || ext == "tif" { return .unsupported("convert to PNG or JPEG to include") }

        do {
            if ext == "pdf" { return extractPDF(url) }
            if ext == "ipynb" { return clean(try extractNotebook(url), empty: "empty notebook") }
            if ext == "pptx" { return clean(try extractPPTX(url), empty: "no slide text") }
            if richTextTypes.contains(ext) { return clean(try await extractRichText(url), empty: "no text") }
            if isPlainText(url) || looksLikeText(url) {
                return clean(try readText(url), empty: "empty file")
            }
            return .unsupported("not a text document")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Text of any document type the library can extract, for the Read tool.
    static func readableText(_ url: URL) async -> String? {
        if case .text(let text) = await extract(url) { return text }
        return nil
    }

    private static func clean(_ text: String, empty: String) -> Extraction {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .unsupported(empty) : .text(trimmed)
    }

    private static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maxTextBytes else { throw AppError.processFailed("file is too large") }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(decoding: data, as: UTF8.self)
    }

    private static func looksLikeText(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let sample = (try? handle.read(upToCount: 4096)) ?? Data()
        return !sample.isEmpty && !sample.contains(0) && String(data: sample, encoding: .utf8) != nil
    }

    private static func extractPDF(_ url: URL) -> Extraction {
        guard let document = PDFDocument(url: url) else { return .failed("could not open PDF") }
        var pages: [String] = []
        for index in 0..<document.pageCount {
            let text = document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            pages.append("[Page \(index + 1)]\n\(text)")
        }
        let letters = pages.joined().filter(\.isLetter).count
        // Scanned or image-only PDFs have little or no text layer.
        if document.pageCount > 0, letters < 40 * document.pageCount + 20 {
            return .vision("scanned PDF, read on demand")
        }
        return .text(pages.joined(separator: "\n\n"))
    }

    @MainActor
    private static func extractRichText(_ url: URL) throws -> String {
        // HTML import requires the main thread; the other formats are fine here too.
        let attributed = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        return attributed.string
    }

    /// Cell sources and text outputs only; embedded images would waste tokens.
    private static func extractNotebook(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cells = root["cells"] as? [[String: Any]] else {
            throw AppError.processFailed("not a valid notebook")
        }
        func joined(_ value: Any?) -> String {
            if let lines = value as? [String] { return lines.joined() }
            return value as? String ?? ""
        }
        var parts: [String] = []
        for (index, cell) in cells.enumerated() {
            let kind = cell["cell_type"] as? String ?? "cell"
            var text = "[Cell \(index + 1) · \(kind)]\n" + joined(cell["source"])
            for output in cell["outputs"] as? [[String: Any]] ?? [] {
                let data = output["data"] as? [String: Any]
                let value = joined(output["text"] ?? data?["text/plain"])
                if !value.isEmpty { text += "\n[Output]\n" + String(value.prefix(4_000)) }
            }
            parts.append(text)
        }
        return parts.joined(separator: "\n\n")
    }

    private static func extractPPTX(_ url: URL) throws -> String {
        let listing = try unzip(["-Z1", url.path])
        let slides = listing.split(separator: "\n").map(String.init)
            .filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var output: [String] = []
        for (index, slide) in slides.enumerated() {
            let xml = try unzip(["-p", url.path, slide])
            let runs = matches(of: #"<a:t>([^<]*)</a:t>"#, in: xml).map(decodeEntities)
            output.append("[Slide \(index + 1)]\n" + runs.joined(separator: " "))
        }
        return output.joined(separator: "\n\n")
    }

    private static func unzip(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw AppError.processFailed("could not read presentation") }
        return String(decoding: data, as: UTF8.self)
    }

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    private static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Conservative estimate. Measured on a real course folder (slides, PDFs,
    /// notebooks), Claude counted about one token per two UTF-8 bytes.
    static func estimateTokens(_ text: String) -> Int {
        max(1, text.utf8.count / 2)
    }

    // MARK: Prompt block

    private static func documentsBlock(_ documents: [(file: ContextFile, text: String)], onDemand: [URL], roots: [URL]) -> String {
        guard !documents.isEmpty || !onDemand.isEmpty else { return "" }
        var block = "<documents>\n"
        for (index, document) in documents.enumerated() {
            let content = document.text.replacingOccurrences(of: "</document_content>", with: "</document_content_>")
            block += """
            <document index="\(index + 1)">
            <source>\(document.file.displayPath)</source>
            <path>\(document.file.url.path)</path>
            <document_content>
            \(content)
            </document_content>
            </document>

            """
        }
        block += "</documents>\n"
        if !onDemand.isEmpty {
            block += "\n<on_demand_files>\nThese reference files are not embedded above. Open them with Read when a question needs them.\n"
            block += onDemand.map { "- \($0.path) (\(displayPath(for: $0, roots: roots)))" }.joined(separator: "\n")
            block += "\n</on_demand_files>\n"
        }
        return block
    }
}
