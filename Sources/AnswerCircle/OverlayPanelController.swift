import AppKit
import SwiftUI

final class OverlayPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

@MainActor
final class OverlayPanelController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var panel: OverlayPanel?
    private var outsideClickMonitor: Any?
    private var escapeMonitor: Any?
    private var contentHeight: CGFloat = 52

    private let savedXKey = "Shortcut.ChatPanelTopLeftX"
    private let savedTopKey = "Shortcut.ChatPanelTopLeftY"

    var isVisible: Bool { panel?.isVisible == true }
    var hasKeyboardFocus: Bool { panel?.isVisible == true && panel?.isKeyWindow == true }

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func show() {
        if panel == nil { makePanel() }
        guard let panel else { return }
        if panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            focusEditor()
            return
        }
        restorePosition(panel)
        panel.alphaValue = 0
        // Non-activating: the app the user was in stays frontmost.
        panel.makeKeyAndOrderFront(nil)
        focusEditor()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            panel.animator().alphaValue = 1
        }
        installDismissMonitors()
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        removeDismissMonitors()
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    func windowDidMove(_ notification: Notification) {
        guard let panel, panel.isVisible else { return }
        UserDefaults.standard.set(panel.frame.minX, forKey: savedXKey)
        UserDefaults.standard.set(panel.frame.maxY, forKey: savedTopKey)
    }

    private func makePanel() {
        let root = ChatOverlayView(
            model: model,
            onHeightChange: { [weak self] height in self?.contentHeightChanged(height) },
            onClose: { [weak self] in self?.close() }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        let panel = OverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: ChatOverlayView.width, height: contentHeight),
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Must stay false: the panel is shown while another app is active.
        panel.hidesOnDeactivate = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .none
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.close() }
        self.panel = panel
    }

    private func contentHeightChanged(_ height: CGFloat) {
        guard height > 0, abs(height - contentHeight) >= 1 else { return }
        contentHeight = height
        guard let panel else { return }
        let top = panel.frame.maxY
        panel.setFrame(
            NSRect(x: panel.frame.minX, y: top - height, width: ChatOverlayView.width, height: height),
            display: true
        )
        if panel.isVisible { constrainToVisibleScreen(panel) }
        panel.invalidateShadow()
    }

    private func focusEditor() {
        guard let panel, let editor = findEditor(in: panel.contentView) else { return }
        panel.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
    }

    private func findEditor(in view: NSView?) -> ImagePastingTextView? {
        guard let view else { return nil }
        if let editor = view as? ImagePastingTextView { return editor }
        for subview in view.subviews {
            if let editor = findEditor(in: subview) { return editor }
        }
        return nil
    }

    private func restorePosition(_ panel: NSPanel) {
        let defaults = UserDefaults.standard
        let size = NSSize(width: ChatOverlayView.width, height: contentHeight)
        if defaults.object(forKey: savedXKey) != nil, defaults.object(forKey: savedTopKey) != nil {
            let x = defaults.double(forKey: savedXKey)
            let top = defaults.double(forKey: savedTopKey)
            panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: false)
        } else if let visible = screenUnderMouse()?.visibleFrame {
            // Spotlight-like default: centred, a little above the middle.
            let top = visible.maxY - visible.height * 0.22
            panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: top - size.height,
                                  width: size.width, height: size.height), display: false)
        }
        constrainToVisibleScreen(panel)
    }

    private func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func constrainToVisibleScreen(_ panel: NSPanel) {
        let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        let screen = NSScreen.screens.first(where: { $0.visibleFrame.insetBy(dx: -40, dy: -40).contains(topLeft) })
            ?? screenUnderMouse()
        guard let visible = screen?.visibleFrame else { return }
        let x = min(max(panel.frame.minX, visible.minX + 8), visible.maxX - panel.frame.width - 8)
        let y = min(max(panel.frame.minY, visible.minY + 8), visible.maxY - panel.frame.height - 8)
        if x != panel.frame.minX || y != panel.frame.minY {
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    private func installDismissMonitors() {
        removeDismissMonitors()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, let panel = self.panel, !panel.frame.contains(NSEvent.mouseLocation) else { return }
                self.close()
            }
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, event.window === self.panel else { return event }
            self.close()
            return nil
        }
    }

    private func removeDismissMonitors() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        outsideClickMonitor = nil
        escapeMonitor = nil
    }
}
