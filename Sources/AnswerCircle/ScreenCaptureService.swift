import AppKit
import ScreenCaptureKit

actor ScreenCaptureService {
    /// Captures the frontmost normal window of `processID` into its own
    /// temporary directory. The caller deletes `url.deletingLastPathComponent()`.
    func captureActiveWindow(processID: pid_t) async throws -> URL {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            appLog.error("SCShareableContent failed: \(error.localizedDescription, privacy: .public)")
            throw AppError.permissionRequired(Self.permissionHelp)
        }

        let candidates = content.windows.filter { window in
            window.owningApplication?.processID == processID &&
            window.windowLayer == 0 &&
            window.frame.width >= 160 && window.frame.height >= 120
        }
        guard let window = Self.frontmost(of: candidates) else {
            appLog.error("No capturable window for pid \(processID); \(content.windows.count) windows visible")
            throw AppError.noWindow
        }

        let scale = NSScreen.screens.first(where: { $0.frame.intersects(window.frame) })?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(window.frame.width * scale))
        configuration.height = max(1, Int(window.frame.height * scale))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureResolution = .best

        let image: CGImage
        do {
            let filter = SCContentFilter(desktopIndependentWindow: window)
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            appLog.error("SCScreenshotManager failed: \(error.localizedDescription, privacy: .public)")
            throw AppError.permissionRequired(Self.permissionHelp)
        }

        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw AppError.processFailed("The captured window could not be encoded.")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Shortcut-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("window.png")
        try png.write(to: url, options: .atomic)
        appLog.info("Captured \(window.owningApplication?.applicationName ?? "?", privacy: .public) window \(window.windowID) at \(configuration.width)x\(configuration.height)")
        return url
    }

    static let permissionHelp = """
    macOS blocked the screen capture. In System Settings › Privacy & Security › Screen & System Audio Recording, remove Shortcut with the – button, add it again, then relaunch Shortcut.
    """

    /// CGWindowList is ordered front to back; ScreenCaptureKit's list is not.
    private static func frontmost(of windows: [SCWindow]) -> SCWindow? {
        guard !windows.isEmpty else { return nil }
        let byID = Dictionary(windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for entry in info {
            if let number = entry[kCGWindowNumber as String] as? NSNumber,
               let window = byID[CGWindowID(number.uint32Value)] {
                return window
            }
        }
        return windows.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }
}
