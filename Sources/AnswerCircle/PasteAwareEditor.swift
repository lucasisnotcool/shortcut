import AppKit
import SwiftUI

/// Plain-text editor that grows with its content, accepts pasted images,
/// sends on Return (Shift-Return inserts a newline) and closes on Escape.
struct PasteAwareEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var contentHeight: CGFloat
    var font: NSFont = .systemFont(ofSize: 15)
    let onPasteImage: (NSImage) -> Void
    let onSubmit: () -> Void
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let editor = ImagePastingTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 20))
        editor.delegate = context.coordinator
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.font = font
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.drawsBackground = false
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.autoresizingMask = [.width]
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.string = text
        scroll.documentView = editor
        context.coordinator.configure(editor)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? ImagePastingTextView else { return }
        context.coordinator.configure(editor)
        let width = scroll.contentSize.width
        if width > 0, abs(editor.frame.width - width) > 0.5 {
            editor.setFrameSize(NSSize(width: width, height: editor.frame.height))
        }
        if editor.string != text {
            editor.string = text
            context.coordinator.reportHeight(of: editor)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PasteAwareEditor
        init(parent: PasteAwareEditor) { self.parent = parent }

        func configure(_ editor: ImagePastingTextView) {
            editor.onPasteImage = { [weak self] in self?.parent.onPasteImage($0) }
            editor.onEscape = { [weak self] in self?.parent.onEscape() }
            editor.onLayout = { [weak self, weak editor] in
                guard let editor else { return }
                self?.reportHeight(of: editor)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            reportHeight(of: editor)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else if !textView.hasMarkedText() {
                    parent.onSubmit()
                } else {
                    return false
                }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
                return true
            default:
                return false
            }
        }

        func reportHeight(of editor: NSTextView) {
            guard let layoutManager = editor.layoutManager, let container = editor.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let lineHeight = layoutManager.defaultLineHeight(for: editor.font ?? parent.font)
            let height = ceil(max(layoutManager.usedRect(for: container).height, lineHeight))
            guard abs(height - parent.contentHeight) > 0.5 else { return }
            // Deferred: this can run during a SwiftUI view update.
            RunLoop.main.perform(inModes: [.common]) { [weak self] in
                self?.parent.contentHeight = height
            }
        }
    }
}

final class ImagePastingTextView: NSTextView {
    var onPasteImage: ((NSImage) -> Void)?
    var onEscape: (() -> Void)?
    var onLayout: (() -> Void)?
    private var lastLaidOutWidth: CGFloat = 0

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !fileURLs.isEmpty {
            // Finder copies also carry the file icon as a bitmap; use the files themselves.
            let images = fileURLs.compactMap(NSImage.init(contentsOf:))
            if images.isEmpty {
                pasteAsPlainText(sender)
            } else {
                images.forEach { onPasteImage?($0) }
            }
        } else if pasteboard.availableType(from: [.png, .tiff]) != nil,
                  let image = NSImage(pasteboard: pasteboard) {
            onPasteImage?(image)
        } else {
            pasteAsPlainText(sender)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    // The overlay is a non-activating panel, so don't rely on the main menu
    // to deliver the standard editing shortcuts.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard window?.firstResponder === self, flags == .command || flags == [.command, .shift] else {
            return super.performKeyEquivalent(with: event)
        }
        switch (event.charactersIgnoringModifiers?.lowercased(), flags == .command) {
        case ("v", true): paste(nil)
        case ("c", true): copy(nil)
        case ("x", true): cut(nil)
        case ("a", true): selectAll(nil)
        case ("z", true): undoManager?.undo()
        case ("z", false): undoManager?.redo()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if abs(newSize.width - lastLaidOutWidth) > 0.5 {
            lastLaidOutWidth = newSize.width
            onLayout?()
        }
    }
}
