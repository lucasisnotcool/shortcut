import AppKit
import SwiftUI
import Testing
@testable import AnswerCircle

/// Renders the chat overlay in its main states for visual review.
/// Runs only when SHORTCUT_SNAPSHOT_DIR is set.
@Test @MainActor func renderOverlaySnapshots() throws {
    guard let directory = ProcessInfo.processInfo.environment["SHORTCUT_SNAPSHOT_DIR"] else { return }
    _ = NSApplication.shared

    let sample = NSImage(size: NSSize(width: 400, height: 240), flipped: false) { rect in
        NSColor.systemTeal.setFill(); rect.fill(); return true
    }
    let states: [(String, (AppModel) -> Void)] = [
        ("empty", { _ in }),
        ("draft", { $0.draft = "Explain why photosynthesis needs light, in two sentences, and give an example that a Secondary 2 student would understand." }),
        ("chat", {
            $0.messages = [
                ChatMessage(role: .user, text: "What is the powerhouse of the cell?", images: []),
                ChatMessage(role: .assistant, text: "The **mitochondrion**. It produces most of the cell's ATP through cellular respiration.\n\nIn the Sec 2 notes this is covered in *Chapter 4*.", images: [])
            ]
        }),
        ("answer", {
            $0.messages = [
                ChatMessage(role: .user, text: "Check the question in the active window.", images: [sample], isWindowCheck: true),
                ChatMessage(role: .assistant, text: "7 × 8 = 56, which is listed as option B. The other options are common multiplication slips.", images: [], answer: AnswerTag(kind: .single, values: ["B"]))
            ]
        }),
        ("noanswer", {
            $0.messages = [
                ChatMessage(role: .user, text: "Check the question in the active window.", images: [sample], isWindowCheck: true),
                ChatMessage(role: .assistant, text: "The window shows a code editor; no multiple-choice question with options is visible.", images: [], answer: AnswerTag(kind: .none, values: []))
            ]
        }),
        ("mrq", {
            $0.messages = [
                ChatMessage(role: .user, text: "Check the question in the active window.", images: [sample], isWindowCheck: true),
                ChatMessage(role: .assistant, text: "Options 1, 3 and 4 are evidence.\n\n**1** ✓  Measured data.\n**2** ✗  An opinion.\n**3** ✓  Peer-reviewed.\n**4** ✓  Replicated.", images: [], answer: AnswerTag(kind: .multiple, values: ["1", "3", "4"]))
            ]
        }),
        ("truefalse", {
            $0.messages = [
                ChatMessage(role: .user, text: "Check the question in the active window.", images: [], isWindowCheck: true),
                ChatMessage(role: .assistant, text: "The notes state the opposite.\n\n**T** ✗  Contradicted by Week 2.\n**F** ✓  Matches Week 2.", images: [], answer: AnswerTag(kind: .trueFalse, values: ["F"]))
            ]
        }),
        ("ranking", {
            $0.messages = [
                ChatMessage(role: .user, text: "Check the question in the active window.", images: [], isWindowCheck: true),
                ChatMessage(role: .assistant, text: "Alphabetical order.\n\n1st  **3**  a\n2nd  **2**  b\n3rd  **5**  c\n4th  **4**  d\n5th  **1**  e", images: [], answer: AnswerTag(kind: .ranking, values: ["3", "2", "5", "4", "1"]))
            ]
        }),
        ("matching", {
            $0.messages = [
                ChatMessage(role: .user, text: "Check the question in the active window.", images: [], isWindowCheck: true),
                ChatMessage(role: .assistant, text: "Organelle functions.\n\n**1** Mitochondria → **B** energy\n**2** Ribosome → **D** proteins\n**3** Nucleus → **A** DNA\n**4** Golgi → **C** packaging", images: [], answer: AnswerTag(kind: .matching, values: ["B", "D", "A", "C"]))
            ]
        }),
        ("fillblank", {
            $0.messages = [
                ChatMessage(role: .user, text: "Check the question in the active window.", images: [], isWindowCheck: true),
                ChatMessage(role: .assistant, text: "From the Week 3 notes.\n\n**Blank 1:** photosynthesis\n**Blank 2:** glucose", images: [], answer: AnswerTag(kind: .fillBlank, values: ["photosynthesis", "glucose"]))
            ]
        }),
        ("pasted", {
            $0.addPastedImage(sample)
            $0.messages = [ChatMessage(role: .user, text: "Pending question", images: [])]
        })
    ]

    for (name, configure) in states {
        let model = AppModel(conversation: ConversationStore(directory: nil))
        configure(model)
        var measured: CGFloat = 0
        let view = ChatOverlayView(model: model, onHeightChange: { measured = $0 })
        // Dark mode over white is the worst case for the translucent card.
        let hosting = NSHostingView(rootView: view.padding(30).background(Color.white).environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: ChatOverlayView.width + 60, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        hosting.appearance = window.appearance
        window.contentView = hosting
        for _ in 0..<5 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("overlay-\(name).png"))
        print("snapshot \(name): card height \(measured)")
    }
}

@Test @MainActor func renderMainWindowSnapshot() async throws {
    guard let directory = ProcessInfo.processInfo.environment["SHORTCUT_SNAPSHOT_DIR"] else { return }
    _ = NSApplication.shared
    let model = AppModel(conversation: ConversationStore(directory: nil))
    if let folder = ProcessInfo.processInfo.environment["SHORTCUT_CONTEXT_DIR"] {
        model.addContextRoots([URL(fileURLWithPath: folder)])
        _ = await model.refreshContext().value
    }
    let shot = NSImage(size: NSSize(width: 860, height: 340), flipped: false) { rect in
        NSColor.white.setFill(); rect.fill(); return true
    }
    model.messages = [
        ChatMessage(role: .user, text: "Which reference files are loaded?", images: []),
        ChatMessage(role: .assistant, text: "**Embedded reference documents: 3**\n\nBiology/Week 1 notes.pdf\n…", images: []),
        ChatMessage(role: .user, text: "Check the question in the active window.", images: [shot], isWindowCheck: true),
        ChatMessage(role: .assistant, text: "The Week 1 notes define the mitochondrion as the site of aerobic respiration, which matches option C.", images: [], answer: AnswerTag(kind: .single, values: ["C"]))
    ]
    let hosting = NSHostingView(rootView: MainView(model: model))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 700),
                          styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
    window.contentView = hosting
    for _ in 0..<8 {
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
    let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    try #require(rep.representation(using: .png, properties: [:]))
        .write(to: URL(fileURLWithPath: directory).appendingPathComponent("main-window.png"))
}

@Test @MainActor func renderPromptEditorSnapshot() throws {
    guard let directory = ProcessInfo.processInfo.environment["SHORTCUT_SNAPSHOT_DIR"] else { return }
    _ = NSApplication.shared
    let model = AppModel(conversation: ConversationStore(directory: nil))
    let hosting = NSHostingView(rootView: PromptEditorView(model: model))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = hosting
    for _ in 0..<5 {
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
    let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    try #require(rep.representation(using: .png, properties: [:]))
        .write(to: URL(fileURLWithPath: directory).appendingPathComponent("prompt-editor.png"))
}

@Test @MainActor func renderMenuBarBadges() throws {
    guard let directory = ProcessInfo.processInfo.environment["SHORTCUT_SNAPSHOT_DIR"] else { return }
    let texts: [String?] = [nil, "B", "12", "!", "×", "✎", "1 3 4", "3 2 5 4 1", "B D A C", "3.14159265", "123456789…"]
    let images = texts.map(StatusItemController.badgeImage(text:))
    let width = images.reduce(CGFloat(10)) { $0 + $1.size.width + 10 }
    let canvas = NSImage(size: NSSize(width: width, height: 22), flipped: false) { rect in
        NSColor.white.setFill(); rect.fill()
        var x: CGFloat = 10
        for image in images {
            image.draw(in: NSRect(x: x, y: 2, width: image.size.width, height: image.size.height))
            x += image.size.width + 10
        }
        return true
    }
    let big = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * 4), pixelsHigh: 88, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: big)
    canvas.draw(in: NSRect(x: 0, y: 0, width: width * 4, height: 88))
    NSGraphicsContext.restoreGraphicsState()
    try #require(big.representation(using: .png, properties: [:]))
        .write(to: URL(fileURLWithPath: directory).appendingPathComponent("badges.png"))
}
