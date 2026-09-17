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
    #expect(answer == WindowAnswer(options: ["B"], explanation: "Because B follows."))
}

@Test func parsesStructuredResultString() throws {
    let data = #"{"result":"```json\n{\"selected_option\":\"3\",\"explanation\":\"Three is correct.\"}\n```"}"#.data(using: .utf8)!
    let answer = try ClaudeOutputParser.windowAnswer(from: data)
    #expect(answer.options == ["3"])
}

@Test @MainActor func validatesOptions() {
    #expect(AppModel.isValidOption("a"))
    #expect(AppModel.isValidOption(" 4 "))
    #expect(AppModel.isValidOption("E"))
    #expect(AppModel.isValidOption("8"))
    #expect(!AppModel.isValidOption("I"))
    #expect(!AppModel.isValidOption("9"))
    #expect(!AppModel.isValidOption("NONE"))
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
    #expect(answer.storageValue == "NONE")
}

@Test func extractsResultFromStreamJSON() throws {
    let stream = """
    {"type":"system","subtype":"init"}
    {"type":"assistant","message":{"content":[]}}
    {"type":"result","subtype":"success","is_error":false,"result":"{\\"selected_option\\":\\"C\\",\\"explanation\\":\\"From the notes.\\"}"}

    """
    let answer = try ClaudeOutputParser.windowAnswer(from: ClaudeOutputParser.resultLine(from: Data(stream.utf8)))
    #expect(answer == WindowAnswer(options: ["C"], explanation: "From the notes."))
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

private func parse(_ json: String) throws -> WindowAnswer {
    let envelope = try JSONSerialization.data(withJSONObject: ["result": json])
    return try ClaudeOutputParser.windowAnswer(from: envelope)
}

@Test func multipleResponseAnswersAreCollectedInOrder() throws {
    let answer = try parse("""
    {"question_type":"multiple","options":[
      {"option":"4","is_answer":true,"reason":"r4"},{"option":"1","is_answer":true,"reason":"r1"},
      {"option":"2","is_answer":false,"reason":"r2"},{"option":"3","is_answer":true,"reason":"r3"}],
     "explanation":"Three apply."}
    """)
    #expect(answer.options == ["1", "3", "4"])
    #expect(answer.isMultiple)
    #expect(answer.storageValue == "1,3,4")
    #expect(answer.label == "1, 3, 4")
    #expect(answer.chatText.contains("**2** ✗  r2"))
    #expect(WindowAnswer.labels(fromStorage: answer.storageValue) == ["1", "3", "4"])
}

@Test func negatedMultipleResponseCanHaveOneAnswer() throws {
    let answer = try parse("""
    {"question_type":"multiple","options":[
      {"option":"1","is_answer":false,"reason":"is evidence"},{"option":"2","is_answer":true,"reason":"is not evidence"},
      {"option":"3","is_answer":false,"reason":"is evidence"},{"option":"4","is_answer":false,"reason":"is evidence"}],
     "explanation":"Only 2 is NOT evidence."}
    """)
    #expect(answer.options == ["2"])
    #expect(answer.isMultiple)
}

@Test func singleWithSeveralCorrectBecomesMultiple() throws {
    let answer = try parse("""
    {"question_type":"single","options":[{"option":"a","is_answer":true,"reason":""},{"option":"(C)","is_answer":true,"reason":""}],"explanation":"x"}
    """)
    #expect(answer.options == ["A", "C"])
    #expect(answer.isMultiple)
}

@Test func trueFalseUsesItsOwnLabels() throws {
    let answer = try parse("""
    {"question_type":"true_false","options":[{"option":"T","is_answer":false,"reason":"no"},{"option":"False","is_answer":true,"reason":"yes"}],"explanation":"It is false."}
    """)
    #expect(answer.options == ["F"])
    #expect(answer.isTrueFalse)
    #expect(!answer.isMultiple)
    #expect(answer.label == "False")
    // Both marked correct is rejected.
    #expect(throws: AppError.self) { try parse("""
    {"question_type":"true_false","options":[{"option":"T","is_answer":true,"reason":""},{"option":"F","is_answer":true,"reason":""}],"explanation":"x"}
    """) }
    // Number labels are not valid for a true/false question, and T is not valid elsewhere.
    #expect(throws: AppError.self) { try parse("""
    {"question_type":"true_false","options":[{"option":"1","is_answer":true,"reason":""}],"explanation":"x"}
    """) }
    #expect(throws: AppError.self) { try parse("""
    {"question_type":"single","options":[{"option":"T","is_answer":true,"reason":""}],"explanation":"x"}
    """) }
}

@Test func malformedAnswersAreRejected() {
    // Mixed families.
    #expect(throws: AppError.self) { try parse("""
    {"question_type":"multiple","options":[{"option":"1","is_answer":true,"reason":""},{"option":"B","is_answer":true,"reason":""}],"explanation":"x"}
    """) }
    // Out of range.
    #expect(throws: AppError.self) { try parse("""
    {"question_type":"single","options":[{"option":"9","is_answer":true,"reason":""}],"explanation":"x"}
    """) }
    // Unknown type, and options without a type.
    #expect(throws: AppError.self) { try parse(#"{"question_type":"essay","options":[],"explanation":"x"}"#) }
    #expect(throws: AppError.self) { try parse(#"{"options":[{"option":"1","is_answer":true}],"explanation":"x"}"#) }
}

@Test func declinedAnswersHaveNoOptions() throws {
    #expect(try parse(#"{"question_type":"none","options":[],"explanation":"No question."}"#).isNoAnswer)
    #expect(try parse(#"{"question_type":"multiple","options":[{"option":"1","is_answer":false,"reason":""}],"explanation":"x"}"#).isNoAnswer)
}
