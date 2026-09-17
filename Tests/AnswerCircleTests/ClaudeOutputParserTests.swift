import AppKit
import Foundation
import Testing
@testable import AnswerCircle

@Test func parsesChatEnvelope() throws {
    let data = #"{"result":"The answer is concise."}"#.data(using: .utf8)!
    #expect(try ClaudeOutputParser.chatText(from: data) == "The answer is concise.")
}

@Test func parsesStructuredOutput() throws {
    let data = #"{"structured_output":{"selected_option":"B","explanation":"Because B follows."}}"#.data(using: .utf8)!
    let answer = try ClaudeOutputParser.windowAnswer(from: data)
    #expect(answer == WindowAnswer(option: "B", explanation: "Because B follows."))
}

@Test func parsesStructuredResultString() throws {
    let data = #"{"result":"```json\n{\"selected_option\":\"3\",\"explanation\":\"Three is correct.\"}\n```"}"#.data(using: .utf8)!
    let answer = try ClaudeOutputParser.windowAnswer(from: data)
    #expect(answer.option == "3")
}

@Test @MainActor func validatesOptions() {
    #expect(AppModel.isValidOption("a"))
    #expect(AppModel.isValidOption(" 4 "))
    #expect(!AppModel.isValidOption("E"))
}

@Test func sameOptionDoubleTapShowsChat() {
    var recognizer = OptionGestureRecognizer()
    #expect(recognizer.handleModifierTransition(key: 58, optionModifierPresent: true, timestamp: 1.00) == .none)
    #expect(recognizer.handleModifierTransition(key: 58, optionModifierPresent: false, timestamp: 1.05) == .none)
    #expect(recognizer.handleModifierTransition(key: 58, optionModifierPresent: true, timestamp: 1.20) == .none)
    #expect(recognizer.handleModifierTransition(key: 58, optionModifierPresent: false, timestamp: 1.25) == .showChat)
}

@Test func bothOptionsCaptureWindowOnce() {
    var recognizer = OptionGestureRecognizer()
    #expect(recognizer.handleModifierTransition(key: 58, optionModifierPresent: true, timestamp: 2.00) == .none)
    #expect(recognizer.handleModifierTransition(key: 61, optionModifierPresent: true, timestamp: 2.04) == .captureWindow)
    #expect(recognizer.handleModifierTransition(key: 61, optionModifierPresent: true, timestamp: 2.10) == .none)
    #expect(recognizer.handleModifierTransition(key: 58, optionModifierPresent: false, timestamp: 2.14) == .none)
}

@Test func optionUsedWithAnotherInputDoesNotOpenChat() {
    var recognizer = OptionGestureRecognizer()
    #expect(recognizer.handleModifierTransition(key: 61, optionModifierPresent: true, timestamp: 3.00) == .none)
    recognizer.invalidateBarePresses()
    #expect(recognizer.handleModifierTransition(key: 61, optionModifierPresent: false, timestamp: 3.10) == .none)
}

@Test func errorEnvelopeSurfacesMessage() {
    let data = #"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Credit balance is too low"}"#.data(using: .utf8)!
    #expect(throws: AppError.self) { try ClaudeOutputParser.chatText(from: data) }
    #expect(ClaudeOutputParser.errorText(from: data) == "Credit balance is too low")
}

@Test func nonJSONOutputIsReportedAsMalformed() {
    let data = "Error: something broke".data(using: .utf8)!
    #expect(throws: AppError.self) { try ClaudeOutputParser.windowAnswer(from: data) }
    #expect(ClaudeOutputParser.errorText(from: data) == nil)
}

@Test @MainActor func noAnswerIsAccepted() throws {
    let data = #"{"structured_output":{"selected_option":"NONE","explanation":"No question visible."}}"#.data(using: .utf8)!
    let answer = try ClaudeOutputParser.windowAnswer(from: data)
    #expect(answer.isNoAnswer)
    #expect(AppModel.isValidOption(answer.option))
}

@Test func extractsResultFromStreamJSON() throws {
    let stream = """
    {"type":"system","subtype":"init"}
    {"type":"assistant","message":{"content":[]}}
    {"type":"result","subtype":"success","is_error":false,"result":"{\\"selected_option\\":\\"C\\",\\"explanation\\":\\"From the notes.\\"}"}

    """
    let answer = try ClaudeOutputParser.windowAnswer(from: ClaudeOutputParser.resultLine(from: Data(stream.utf8)))
    #expect(answer == WindowAnswer(option: "C", explanation: "From the notes."))
}

@Test func buildsInlineImageMessage() throws {
    let image = NSImage(size: NSSize(width: 3000, height: 1000), flipped: false) { rect in
        NSColor.white.setFill(); rect.fill(); return true
    }
    let line = try ClaudeService.userMessageLine(text: "Q?", images: [try ClaudeImage(image: image)])
    #expect(line.last == 0x0A)
    let object = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
    let content = try #require((object["message"] as? [String: Any])?["content"] as? [[String: Any]])
    #expect(content.map { $0["type"] as? String } == ["image", "text"])
    let source = try #require(content[0]["source"] as? [String: Any])
    let data = try #require(Data(base64Encoded: source["data"] as? String ?? ""))
    let rep = try #require(NSBitmapImageRep(data: data))
    #expect(max(rep.pixelsWide, rep.pixelsHigh) <= 2000)
}

@Test func bareOptionTapsAreNeverDelivered() {
    var filter = OptionKeyFilter()
    for _ in 0..<2 {
        #expect(filter.handle(.option(key: 58, isDown: true, withOtherModifiers: false)) == .swallow)
        #expect(filter.handle(.option(key: 58, isDown: false, withOtherModifiers: false)) == .swallow)
    }
    // Both Option keys together.
    #expect(filter.handle(.option(key: 58, isDown: true, withOtherModifiers: false)) == .swallow)
    #expect(filter.handle(.option(key: 61, isDown: true, withOtherModifiers: false)) == .swallow)
    #expect(filter.handle(.option(key: 61, isDown: false, withOtherModifiers: false)) == .swallow)
    #expect(filter.handle(.option(key: 58, isDown: false, withOtherModifiers: false)) == .swallow)
    #expect(filter.held.isEmpty)
}

@Test func optionChordsStillReachApps() {
    var filter = OptionKeyFilter()
    // Option+key: the held press is replayed before the key, the release passes.
    #expect(filter.handle(.option(key: 61, isDown: true, withOtherModifiers: false)) == .swallow)
    #expect(filter.handle(.otherInput) == .replayThenPass([61]))
    #expect(filter.handle(.otherInput) == .pass)
    #expect(filter.handle(.option(key: 61, isDown: false, withOtherModifiers: false)) == .pass)
    // Option-click with both keys held.
    _ = filter.handle(.option(key: 58, isDown: true, withOtherModifiers: false))
    _ = filter.handle(.option(key: 61, isDown: true, withOtherModifiers: false))
    #expect(filter.handle(.otherInput) == .replayThenPass([58, 61]))
    // Command held first: Option passes straight through.
    var chord = OptionKeyFilter()
    #expect(chord.handle(.option(key: 58, isDown: true, withOtherModifiers: true)) == .pass)
    #expect(chord.handle(.option(key: 58, isDown: false, withOtherModifiers: true)) == .pass)
    // Option first, then Shift: replay before Shift.
    #expect(chord.handle(.option(key: 58, isDown: true, withOtherModifiers: false)) == .swallow)
    #expect(chord.handle(.otherModifier) == .replayThenPass([58]))
}

@Test func promptEditsPersistAndRestore() {
    let defaults = UserDefaults.standard
    let saved = (defaults.object(forKey: "Shortcut.Prompt.Instructions"), defaults.object(forKey: "Shortcut.Prompt.WindowCheck"))
    defer {
        defaults.set(saved.0, forKey: "Shortcut.Prompt.Instructions")
        defaults.set(saved.1, forKey: "Shortcut.Prompt.WindowCheck")
    }
    PromptSettings.instructions = "Custom instructions."
    #expect(PromptSettings.instructions == "Custom instructions.")
    #expect(PromptSettings.isInstructionsCustomized)
    // Setting the default text (or blank) goes back to following the default.
    PromptSettings.instructions = PromptSettings.defaultInstructions
    #expect(!PromptSettings.isInstructionsCustomized)
    PromptSettings.windowCheck = "   "
    #expect(PromptSettings.windowCheck == PromptSettings.defaultWindowCheck)
}
