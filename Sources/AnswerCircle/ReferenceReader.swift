import AppKit
import Foundation
import PDFKit

/// The Read tool for API models: the same read-only access the CLI gets
/// with `--add-dir`, limited to the reference folders.
struct ReferenceReader {
    static let toolName = "Read"
    static let toolDescription = """
    Open a reference file listed in the instructions (an on-demand file, or the original of an embedded document). \
    Returns its text; images and pages of scanned PDFs come back as images. Read-only, limited to the reference folders.
    """
    static let parameterSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "file_path": ["type": "string", "description": "Absolute path of the file, exactly as listed."],
            "pages": ["type": "string", "description": "PDF pages to read, such as \"3\" or \"2-5\". Optional."]
        ],
        "required": ["file_path"]
    ]

    static let maxCharacters = 150_000
    static let maxRenderedPages = 5
    static let maxTextPages = 40

    struct Output {
        var text: String
        var images: [ClaudeImage] = []
        var isError = false
    }

    /// Folders the model may read, symlinks resolved.
    let allowedDirectories: [String]

    init(directories: [String]) {
        allowedDirectories = directories.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path }
    }

    func isAllowed(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return allowedDirectories.contains { path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    func run(_ arguments: [String: Any]) async -> Output {
        guard let raw = (arguments["file_path"] ?? arguments["path"]) as? String, !raw.isEmpty else {
            return Output(text: "Read needs a file_path.", isError: true)
        }
        let path = (raw as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        appLog.info("Read tool: \(url.lastPathComponent, privacy: .public)")
        guard url.path.hasPrefix("/"), isAllowed(url) else {
            return Output(text: "Access denied: \(raw) is outside the reference folders.", isError: true)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return Output(text: "No such file: \(raw)", isError: true)
        }
        let pages = Self.pageRange(arguments["pages"])
        let ext = url.pathExtension.lowercased()
        do {
            if ["png", "jpg", "jpeg", "gif", "webp"].contains(ext) {
                return Output(text: "Image \(url.lastPathComponent):", images: [try ClaudeImage(fileURL: url)])
            }
            if ext == "pdf" { return try readPDF(url, pages: pages) }
            guard let text = await ContextLibrary.readableText(url) else {
                return Output(text: "\(url.lastPathComponent) has no readable text.", isError: true)
            }
            return Output(text: Self.truncated(text))
        } catch {
            return Output(text: "Could not read \(url.lastPathComponent): \(error.localizedDescription)", isError: true)
        }
    }

    private func readPDF(_ url: URL, pages: ClosedRange<Int>?) throws -> Output {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            return Output(text: "Could not open \(url.lastPathComponent).", isError: true)
        }
        let count = document.pageCount
        let first = max(1, min(pages?.lowerBound ?? 1, count))
        let last = min(count, pages?.upperBound ?? count)
        let textPages = (first...last).prefix(Self.maxTextPages).map { index in
            (index, document.page(at: index - 1)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
        let letters = textPages.reduce(0) { $0 + $1.1.filter(\.isLetter).count }
        if letters >= 40 * textPages.count {
            var text = textPages.map { "[Page \($0.0)]\n\($0.1)" }.joined(separator: "\n\n")
            if last - first + 1 > Self.maxTextPages {
                text += "\n\n(Stopped after \(Self.maxTextPages) pages; ask for pages \(first + Self.maxTextPages)-\(last) next.)"
            }
            return Output(text: "\(url.lastPathComponent), \(count) pages:\n" + Self.truncated(text))
        }
        // Scanned: render the pages as images.
        let rendered = Array((first...last).prefix(Self.maxRenderedPages))
        let images = try rendered.compactMap { index -> ClaudeImage? in
            guard let page = document.page(at: index - 1) else { return nil }
            let bounds = page.bounds(for: .mediaBox)
            let scale = 1600 / max(bounds.width, bounds.height, 1)
            let image = page.thumbnail(of: NSSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
            return try ClaudeImage(image: image)
        }
        var note = "\(url.lastPathComponent) is scanned; pages \(rendered.first ?? first)-\(rendered.last ?? last) of \(count) are attached as images."
        if last > rendered.last ?? last { note += " Ask for pages \((rendered.last ?? last) + 1)-\(last) next." }
        return Output(text: note, images: images)
    }

    static func pageRange(_ value: Any?) -> ClosedRange<Int>? {
        let text: String
        if let number = value as? Int { text = String(number) } else if let string = value as? String { text = string } else { return nil }
        let bounds = text.split(whereSeparator: { $0 == "-" || $0 == "–" })
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard let lower = bounds.first, lower >= 1 else { return nil }
        let upper = bounds.count > 1 ? bounds[1] : lower
        return lower...max(lower, upper)
    }

    private static func truncated(_ text: String) -> String {
        guard text.count > maxCharacters else { return text }
        return String(text.prefix(maxCharacters)) + "\n\n(Truncated at \(maxCharacters) characters.)"
    }
}
