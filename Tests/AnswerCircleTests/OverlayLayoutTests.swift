import AppKit
import SwiftUI
import Testing
@testable import AnswerCircle

/// With "always show scroll bars", a reply near the height limit used to make
/// the scroller appear and disappear forever, pinning the main thread.
@Test @MainActor func overlayHeightSettlesWithLegacyScrollers() throws {
    _ = NSApplication.shared
    UserDefaults.standard.set("Always", forKey: "AppleShowScrollBars")
    defer { UserDefaults.standard.removeObject(forKey: "AppleShowScrollBars") }

    var worst = 0
    for imageHeight in stride(from: 240, through: 420, by: 6) {
        let shot = NSImage(size: NSSize(width: 1416, height: imageHeight * 1416 / 528), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill(); return true
        }
        let model = AppModel(conversation: ConversationStore(directory: nil))
        model.messages = [
            ChatMessage(role: .user, text: "Check the question in the active window.", images: [shot], isWindowCheck: true),
            ChatMessage(role: .assistant, text: String(repeating: "The lecture notes explain the answer in detail. ", count: 4), images: [], answerOption: "B")
        ]
        var changes = 0
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: ChatOverlayView.width, height: 52),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: ChatOverlayView(model: model, onHeightChange: { height in
            changes += 1
            panel.setContentSize(NSSize(width: ChatOverlayView.width, height: height))
        }))
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.orderFront(nil)
        for _ in 0..<30 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        panel.orderOut(nil)
        worst = max(worst, changes)
        if changes > 8 { print("oscillation at image height \(imageHeight): \(changes) height changes") }
    }
    #expect(worst <= 8)
}
