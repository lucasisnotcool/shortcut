// Shows a demo quiz page in a plain window (no browser toolbar, tabs or
// bookmarks), so screenshots show only mock content.
// Usage: swiftc -o /tmp/quiz-viewer docs/demo/quiz-viewer.swift
//        /tmp/quiz-viewer docs/demo/quizzes/single.html [width height [left top]]
import AppKit
import WebKit

let arguments = CommandLine.arguments
let page = URL(fileURLWithPath: arguments[1]).standardizedFileURL
let width = arguments.count > 2 ? Double(arguments[2]) ?? 820 : 820
let height = arguments.count > 3 ? Double(arguments[3]) ?? 560 : 560

let app = NSApplication.shared
app.setActivationPolicy(.regular)

// A plain backdrop hides everything else on screen, so screenshots of the
// translucent overlay show only the demo. Ordered behind the quiz window, so
// window checks still capture the quiz.
let backdrop = NSWindow(contentRect: NSScreen.main!.frame, styleMask: [.borderless],
                        backing: .buffered, defer: false)
backdrop.backgroundColor = NSColor(red: 0.87, green: 0.89, blue: 0.92, alpha: 1)
backdrop.orderFront(nil)

let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: width, height: height),
    styleMask: [.titled, .closable, .resizable],
    backing: .buffered, defer: false
)
window.title = "Demo Quiz"
let webView = WKWebView(frame: window.contentView!.bounds)
webView.autoresizingMask = [.width, .height]
webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
window.contentView = webView
if arguments.count > 5, let left = Double(arguments[4]), let top = Double(arguments[5]),
   let screen = NSScreen.main {
    window.setFrameTopLeftPoint(NSPoint(x: left, y: screen.frame.maxY - top))
} else {
    window.center()
}
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
