import AppKit
import Foundation
import os

let appLog = Logger(subsystem: "local.lohzh.Shortcut", category: "app")

actor ClaudeService {
    private static let sessionIDKey = "AnswerCircle.ClaudeSessionID"
    private static let sessionStartedKey = "AnswerCircle.ClaudeSessionStarted"
    private static let contextSignatureKey = "AnswerCircle.ClaudeContextSignature"
    private static let requestTimeout: TimeInterval = 240
    static let model = "opus[1m]"
    static let modelDisplayName = "Opus · 1M context"
    /// Identical for chat and window checks: a different tool list would
    /// invalidate the prompt cache that holds the reference documents.
    private static let tools = ["Read", "WebSearch", "WebFetch"]
    private var sessionID: String
    private var sessionHasStarted: Bool
    /// Every request resumes the same session, so requests must never overlap.
    private var queueTail: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: Self.sessionIDKey), UUID(uuidString: saved) != nil {
            sessionID = saved
            sessionHasStarted = defaults.bool(forKey: Self.sessionStartedKey)
        } else {
            sessionID = UUID().uuidString
            sessionHasStarted = false
            defaults.set(sessionID, forKey: Self.sessionIDKey)
            defaults.set(false, forKey: Self.sessionStartedKey)
        }
        // The file manifest used to live in the conversation; it is now part of the system prompt.
        defaults.removeObject(forKey: Self.contextSignatureKey)
    }

    /// Keys that would make the CLI bill somewhere other than the claude.ai
    /// subscription (whose usage credits cover overflow), or that belong to a
    /// parent Claude Code session.
    private static let strippedEnvironment = [
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
        "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"
    ]

    static func childEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in strippedEnvironment { environment.removeValue(forKey: key) }
        environment["PATH"] = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"
        ].joined(separator: ":")
        return environment
    }

    /// "Max plan · you@example.com", from `claude auth status`.
    static func accountSummary() async -> String? {
        guard let executable = locateExecutable() else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["auth", "status"]
        process.environment = childEnvironment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = await Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }.value
        process.waitUntilExit()
        guard let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let method = status["authMethod"] as? String ?? "?"
        let plan = (status["subscriptionType"] as? String).map { $0.prefix(1).uppercased() + $0.dropFirst() + " plan" }
        appLog.notice("Claude CLI auth: method \(method, privacy: .public), plan \(plan ?? "none", privacy: .public)")
        guard status["loggedIn"] as? Bool == true else { return "Not signed in — run claude auth login" }
        if method != "claude.ai" { return "Signed in with \(method) (not a Claude subscription)" }
        return [plan, status["email"] as? String].compactMap { $0 }.joined(separator: " · ")
    }

    static func locateExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude")
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return found
        }
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("claude")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// `prompt` overrides the text sent to Claude (the message text is what the teacher sees).
    /// `prompt` overrides the text sent to Claude (the message text is what the teacher sees).
    func chat(message: ChatMessage, context: ContextSnapshot, prompt: String? = nil) async throws -> String {
        let images = try message.images.map(ClaudeImage.init(image:))
        return try await serialized {
            let output = try await self.runClaude(text: prompt ?? message.text, images: images, context: context)
            return try ClaudeOutputParser.chatText(from: output)
        }
    }

    func answerQuestion(screenshot: URL, context: ContextSnapshot) async throws -> WindowAnswer {
        // JSON is requested in the reply rather than via --json-schema: the schema
        // option adds a tool, which costs an extra turn and breaks the prompt cache.
        let prompt = PromptSettings.windowCheck + "\n\n" + PromptSettings.windowCheckReplyFormat
        let image = try ClaudeImage(fileURL: screenshot)
        return try await serialized {
            let output = try await self.runClaude(text: prompt, images: [image], context: context)
            return try ClaudeOutputParser.windowAnswer(from: output)
        }
    }

    /// Asks Claude to confirm which reference documents it can see.
    static let verificationPrompt = """
    [Context check] Without opening any files, list the reference documents embedded in your instructions: give the total count, then each <source> on its own line. Then list any on-demand files. Keep it brief.
    """

    func resetSession() async {
        await serialized { self.startNewSession() }
    }

    private func startNewSession() {
        sessionID = UUID().uuidString
        sessionHasStarted = false
        UserDefaults.standard.set(sessionID, forKey: Self.sessionIDKey)
        UserDefaults.standard.set(false, forKey: Self.sessionStartedKey)
    }

    private func markSessionStarted() {
        sessionHasStarted = true
        UserDefaults.standard.set(true, forKey: Self.sessionStartedKey)
    }

    private func serialized<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        let previous = queueTail
        let task = Task { () async throws -> T in
            await previous?.value
            return try await operation()
        }
        queueTail = Task { _ = try? await task.value }
        return try await task.value
    }

    private func serialized(_ operation: @escaping () async -> Void) async {
        let previous = queueTail
        let task = Task {
            await previous?.value
            await operation()
        }
        queueTail = task
        await task.value
    }

    /// Runs one turn in the shared session, recovering from the two session
    /// states that would otherwise fail every future request.
    private func runClaude(text: String, images: [ClaudeImage], context: ContextSnapshot) async throws -> Data {
        let systemPromptURL = try writeSystemPrompt(context)
        let message = try Self.userMessageLine(text: text, images: images)
        for attempt in 0..<2 {
            do {
                let output = try await launchClaude(message: message, systemPromptURL: systemPromptURL, directories: context.readableDirectories)
                markSessionStarted()
                return output
            } catch AppError.processFailed(let detail) where attempt == 0 {
                if !sessionHasStarted, detail.localizedCaseInsensitiveContains("already in use") {
                    // An earlier first turn created the session but did not finish.
                    appLog.notice("Session \(self.sessionID, privacy: .public) already exists; resuming it")
                    markSessionStarted()
                    continue
                }
                if sessionHasStarted, detail.localizedCaseInsensitiveContains("No conversation found") {
                    appLog.notice("Session \(self.sessionID, privacy: .public) is gone; starting a new one")
                    startNewSession()
                    continue
                }
                throw AppError.processFailed(detail)
            }
        }
        throw AppError.processFailed("Claude could not start a session.")
    }

    /// Documents first, instructions after (Anthropic long-context guidance).
    /// Rewritten only when it changes, and kept byte-stable for prompt caching.
    static func systemPromptURL() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("AnswerCircle/system-prompt.md")
    }

    private func writeSystemPrompt(_ context: ContextSnapshot) throws -> URL {
        let text = context.documentsBlock.isEmpty
            ? PromptSettings.instructions
            : context.documentsBlock + "\n" + PromptSettings.instructions
        _ = try managedWorkspace()
        let url = try Self.systemPromptURL()
        let data = Data(text.utf8)
        if (try? Data(contentsOf: url)) != data {
            try data.write(to: url, options: .atomic)
        }
        return url
    }

    /// One stream-json user message. Images go inline as content blocks, so
    /// Claude sees them immediately instead of spending a turn on Read.
    static func userMessageLine(text: String, images: [ClaudeImage]) throws -> Data {
        var content: [[String: Any]] = images.map { image in
            ["type": "image", "source": ["type": "base64", "media_type": image.mediaType, "data": image.data.base64EncodedString()]]
        }
        content.append(["type": "text", "text": text.isEmpty ? "(See the attached image.)" : text])
        let line: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        var data = try JSONSerialization.data(withJSONObject: line)
        data.append(0x0A)
        return data
    }

    private func launchClaude(message: Data, systemPromptURL: URL, directories: [String]) async throws -> Data {
        guard let executable = Self.locateExecutable() else { throw AppError.claudeNotFound }

        var arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--model", Self.model,
            "--permission-mode", "dontAsk",
            "--tools", Self.tools.joined(separator: ","),
            "--allowedTools", Self.tools.joined(separator: ","),
            "--strict-mcp-config",
            "--safe-mode",
            "--system-prompt-file", systemPromptURL.path
        ]
        if sessionHasStarted {
            arguments += ["--resume", sessionID]
        } else {
            arguments += ["--session-id", sessionID, "--name", "Shortcut"]
        }
        if !directories.isEmpty {
            arguments.append("--add-dir")
            arguments.append(contentsOf: directories)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = try managedWorkspace()

        process.environment = Self.childEnvironment()

        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Shortcut-output-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let stdinURL = outputDirectory.appendingPathComponent("stdin")
        try message.write(to: stdinURL)
        let stdoutURL = outputDirectory.appendingPathComponent("stdout")
        let stderrURL = outputDirectory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        let stdin = try FileHandle(forReadingFrom: stdinURL)
        defer { try? stdin.close() }
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        appLog.info("Running claude (\(self.sessionHasStarted ? "resume" : "new", privacy: .public) session)")
        let started = Date()
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { task in
                continuation.resume(returning: task.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.requestTimeout) { [process] in
                if process.isRunning { process.terminate() }
            }
        }
        try? stdout.close()
        try? stderr.close()
        let elapsed = Date().timeIntervalSince(started)
        let data = ClaudeOutputParser.resultLine(from: (try? Data(contentsOf: stdoutURL)) ?? Data())

        guard status == 0 else {
            let err = String(data: (try? Data(contentsOf: stderrURL)) ?? Data(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let out = ClaudeOutputParser.errorText(from: data)
            appLog.error("claude exited \(status) after \(elapsed, format: .fixed(precision: 1))s: \(err, privacy: .public) \(out ?? "", privacy: .public)")
            if process.terminationReason == .uncaughtSignal, elapsed >= Self.requestTimeout - 1 {
                throw AppError.processFailed("Claude did not respond within \(Int(Self.requestTimeout)) seconds.")
            }
            let detail = [err, out ?? ""].first { !$0.isEmpty } ?? "Claude exited with status \(status)."
            throw AppError.processFailed(detail)
        }
        if let usage = ClaudeOutputParser.usageSummary(from: data) {
            appLog.info("claude finished in \(elapsed, format: .fixed(precision: 1))s — \(usage, privacy: .public)")
        } else {
            appLog.info("claude finished in \(elapsed, format: .fixed(precision: 1))s")
        }
        return data
    }

    private func managedWorkspace() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let workspace = base.appendingPathComponent("AnswerCircle/ClaudeWorkspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return workspace
    }


}

/// An image ready to send inline, within the API's 5 MB per-image limit.
struct ClaudeImage {
    let data: Data
    let mediaType: String

    private static let maxLongEdge: CGFloat = 2000
    private static let maxBytes = 3_700_000  // 5 MB after base64 encoding

    init(fileURL: URL) throws {
        guard let image = NSImage(contentsOf: fileURL) else {
            throw AppError.processFailed("The screenshot could not be read.")
        }
        try self.init(image: image)
    }

    init(image: NSImage) throws {
        guard var cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw AppError.processFailed("An image could not be converted for Claude.")
        }
        let longEdge = CGFloat(max(cgImage.width, cgImage.height))
        if longEdge > Self.maxLongEdge, let scaled = Self.scale(cgImage, by: Self.maxLongEdge / longEdge) {
            cgImage = scaled
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        if let png = bitmap.representation(using: .png, properties: [:]), png.count <= Self.maxBytes {
            data = png
            mediaType = "image/png"
        } else if let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
            data = jpeg
            mediaType = "image/jpeg"
        } else {
            throw AppError.processFailed("An image could not be converted for Claude.")
        }
    }

    private static func scale(_ image: CGImage, by factor: CGFloat) -> CGImage? {
        let width = max(1, Int(CGFloat(image.width) * factor))
        let height = max(1, Int(CGFloat(image.height) * factor))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

enum ClaudeOutputParser {
    /// The final `result` event from stream-json output (plain JSON passes through).
    static func resultLine(from data: Data) -> Data {
        for line in data.split(separator: 0x0A).reversed() {
            if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
               object["type"] as? String == "result" {
                return Data(line)
            }
        }
        return data
    }

    static func chatText(from data: Data) throws -> String {
        let root = try jsonObject(from: data)
        if root["is_error"] as? Bool == true {
            throw AppError.processFailed(errorText(from: data) ?? "Claude reported an error.")
        }
        if let result = root["result"] as? String, !result.isEmpty { return result }
        if let result = root["response"] as? String, !result.isEmpty { return result }
        throw AppError.invalidResponse("Claude returned no readable response.")
    }

    static func windowAnswer(from data: Data) throws -> WindowAnswer {
        let root = try jsonObject(from: data)
        if let object = root["structured_output"] as? [String: Any],
           let answer = try answer(from: object) {
            return answer
        }
        if let object = root["result"] as? [String: Any],
           let answer = try answer(from: object) {
            return answer
        }
        if let text = root["result"] as? String,
           let nestedData = extractJSONObject(from: text),
           let object = try? JSONSerialization.jsonObject(with: nestedData) as? [String: Any],
           let answer = try answer(from: object) {
            return answer
        }
        if root["is_error"] as? Bool == true {
            throw AppError.processFailed(errorText(from: data) ?? "Claude reported an error.")
        }
        throw AppError.invalidResponse("Claude did not return a structured answer.")
    }

    /// Turns, cache hits and cost, for the log.
    static func usageSummary(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = root["usage"] as? [String: Any] else { return nil }
        let models = (root["modelUsage"] as? [String: Any])?.keys.sorted().joined(separator: ",") ?? "?"
        return "turns \(root["num_turns"] ?? "?"), cache read \(usage["cache_read_input_tokens"] ?? 0), "
            + "cache write \(usage["cache_creation_input_tokens"] ?? 0), input \(usage["input_tokens"] ?? 0), "
            + "cost $\(root["total_cost_usd"] ?? 0), model \(models)"
    }

    /// Best-effort error message from a JSON envelope printed on failure.
    static func errorText(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let errors = root["errors"] as? [String], let first = errors.first { return first }
        if root["is_error"] as? Bool == true, let result = root["result"] as? String, !result.isEmpty { return result }
        return nil
    }

    private static func jsonObject(from data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.invalidResponse("Claude returned malformed JSON.")
        }
        return object
    }

    /// Reads a window-check reply. `question_type` comes first and decides
    /// which fields and labels are valid. The older `selected_option(s)`
    /// format still parses. Returns nil only when the object is not an answer
    /// at all; a malformed answer throws so the teacher sees why.
    private static func answer(from object: [String: Any]) throws -> WindowAnswer? {
        guard let explanation = object["explanation"] as? String else { return nil }
        let rawType = (object["question_type"] as? String)?
            .lowercased().replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        let kind = rawType.flatMap(AnswerKind.init(rawValue:))
        if rawType != nil, kind == nil {
            throw invalid("Claude returned an unknown question type: \(rawType ?? "")")
        }

        switch kind {
        case .none?:
            return .none(explanation)
        case .ranking?:
            return try ranking(object, explanation)
        case .matching?:
            return try matching(object, explanation)
        case .numeric?:
            return try numeric(object, explanation)
        case .fillBlank?:
            return try fillBlank(object, explanation)
        case let choice?:
            if object["options"] != nil { return try choiceAnswer(object, kind: choice, explanation) }
            return try legacy(object, kind: choice, explanation)
        case nil:
            if object["options"] != nil { throw invalid("Claude listed options without a question type.") }
            return try legacy(object, kind: nil, explanation)
        }
    }

    private static func invalid(_ message: String) -> AppError { .invalidResponse(message) }

    private static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    /// single, multiple, true_false, dropdown: a verdict for every option.
    private static func choiceAnswer(_ object: [String: Any], kind: AnswerKind, _ explanation: String) throws -> WindowAnswer {
        guard let entries = object["options"] as? [[String: Any]] else {
            throw invalid("Claude returned options in an unexpected shape.")
        }
        var selected: [String] = []
        var details: [String] = []
        for entry in entries {
            guard let raw = string(entry["option"]), let isAnswer = entry["is_answer"] as? Bool else {
                throw invalid("Claude returned an option without a verdict.")
            }
            let label = try normalizedLabel(raw, for: kind)
            if isAnswer { selected.append(label) }
            let text = (string(entry["text"])).map { " \($0) —" } ?? ""
            details.append("**\(label)** \(isAnswer ? "✓" : "✗")\(text)  \(string(entry["reason"]) ?? "")")
        }
        let values = try validatedSelection(selected, for: kind)
        var finalKind = kind
        switch kind {
        case .trueFalse where values.count > 1:
            throw invalid("Claude marked both True and False as correct.")
        case .dropdown where values.count > 1:
            throw invalid("Claude picked \(values.count) options in a single dropdown.")
        case .single where values.count > 1:
            // Several correct options make it a multiple-response question.
            appLog.notice("Single-answer question came back with \(values.count) answers; treating as multiple")
            finalKind = .multiple
        default:
            break
        }
        if values.isEmpty { return WindowAnswer(tag: AnswerTag(kind: .none, values: []), explanation: explanation, details: details) }
        return WindowAnswer(tag: AnswerTag(kind: finalKind, values: values), explanation: explanation, details: details)
    }

    /// {"items": [{"option", "text"}], "order": [labels first to last]}
    private static func ranking(_ object: [String: Any], _ explanation: String) throws -> WindowAnswer {
        guard let rawOrder = object["order"] as? [Any], !rawOrder.isEmpty else {
            throw invalid("Claude gave a ranking without an order.")
        }
        let order = try rawOrder.map { value -> String in
            guard let raw = string(value) else { throw invalid("Claude gave an unreadable ranking entry.") }
            return try normalizedLabel(raw, for: .ranking)
        }
        try requireOneFamily(order, for: .ranking)
        guard Set(order).count == order.count else {
            throw invalid("Claude's ranking repeats an option: \(order.joined(separator: " "))")
        }
        var texts: [String: String] = [:]
        if let items = object["items"] as? [[String: Any]] {
            for item in items {
                guard let raw = string(item["option"]) else { continue }
                texts[try normalizedLabel(raw, for: .ranking)] = string(item["text"]) ?? ""
            }
            if !texts.isEmpty, Set(texts.keys) != Set(order) {
                throw invalid("Claude's ranking does not use every listed option exactly once.")
            }
        }
        let details = order.enumerated().map { index, label in
            let text = texts[label].map { $0.isEmpty ? "" : "  \($0)" } ?? ""
            return "\(Self.ordinal(index + 1))  **\(label)**\(text)"
        }
        return WindowAnswer(tag: AnswerTag(kind: .ranking, values: order), explanation: explanation, details: details)
    }

    /// {"matches": [{"item", "item_text", "choice", "choice_text", "reason"}]}
    private static func matching(_ object: [String: Any], _ explanation: String) throws -> WindowAnswer {
        guard let entries = object["matches"] as? [[String: Any]], !entries.isEmpty else {
            throw invalid("Claude gave a matching answer without matches.")
        }
        var pairs: [(item: String, choice: String, line: String)] = []
        for entry in entries {
            guard let rawItem = string(entry["item"]), let rawChoice = string(entry["choice"]) else {
                throw invalid("Claude left an item unmatched.")
            }
            let item = try normalizedLabel(rawItem, for: .matching)
            let choice = try normalizedLabel(rawChoice, for: .matching)
            let itemText = string(entry["item_text"]).map { " \($0)" } ?? ""
            let choiceText = string(entry["choice_text"]).map { " \($0)" } ?? ""
            let reason = string(entry["reason"]).map { " — \($0)" } ?? ""
            pairs.append((item, choice, "**\(item)**\(itemText) → **\(choice)**\(choiceText)\(reason)"))
        }
        let items = pairs.map(\.item)
        guard Set(items).count == items.count else {
            throw invalid("Claude matched the same item twice.")
        }
        try requireOneFamily(items, for: .matching)
        try requireOneFamily(pairs.map(\.choice), for: .matching)
        pairs.sort { $0.item.localizedStandardCompare($1.item) == .orderedAscending }
        return WindowAnswer(tag: AnswerTag(kind: .matching, values: pairs.map(\.choice)),
                            explanation: explanation, details: pairs.map(\.line))
    }

    /// {"value": "42", "unit": "kg"}
    private static func numeric(_ object: [String: Any], _ explanation: String) throws -> WindowAnswer {
        guard let value = string(object["value"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, value.count <= 40 else {
            throw invalid("Claude gave a number answer without a usable value.")
        }
        let unit = string(object["unit"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let details = ["**\(value)**\(unit.isEmpty ? "" : " \(unit)")"]
        return WindowAnswer(tag: AnswerTag(kind: .numeric, values: [value]), explanation: explanation, details: details)
    }

    /// {"blanks": [{"blank": "1", "answer": "...", "reason": "..."}]}
    private static func fillBlank(_ object: [String: Any], _ explanation: String) throws -> WindowAnswer {
        guard let entries = object["blanks"] as? [[String: Any]], !entries.isEmpty else {
            throw invalid("Claude gave a fill-in-the-blank answer without blanks.")
        }
        var values: [String] = []
        var details: [String] = []
        for (index, entry) in entries.enumerated() {
            guard let text = string(entry["answer"])?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                throw invalid("Claude left a blank empty.")
            }
            let name = string(entry["blank"]) ?? String(index + 1)
            let reason = string(entry["reason"]).map { " — \($0)" } ?? ""
            values.append(text)
            details.append("**Blank \(name):** \(text)\(reason)")
        }
        return WindowAnswer(tag: AnswerTag(kind: .fillBlank, values: values), explanation: explanation, details: details)
    }

    /// Older format: {"selected_option": "B"} or {"selected_options": [...]}.
    private static func legacy(_ object: [String: Any], kind: AnswerKind?, _ explanation: String) throws -> WindowAnswer? {
        let raw: [String]
        if let list = object["selected_options"] as? [String] {
            raw = list
        } else if let single = object["selected_option"] as? String {
            raw = [single]
        } else {
            return nil
        }
        if raw.contains(where: { $0.trimmingCharacters(in: .whitespaces).uppercased() == "NONE" }) {
            return .none(explanation)
        }
        var effective = kind ?? (raw.count > 1 ? .multiple : .single)
        let values = try validatedSelection(try raw.map { try normalizedLabel($0, for: effective) }, for: effective)
        if effective == .single, values.count > 1 { effective = .multiple }
        return WindowAnswer(tag: AnswerTag(kind: effective, values: values), explanation: explanation)
    }

    /// The label set depends on the declared kind, so "F" means False only in a
    /// true/false question. "b", " 3 ", "(C)", "Option 2.", "True" → "B", "3", "C", "2", "T".
    static func normalizedLabel(_ raw: String, for kind: AnswerKind) throws -> String {
        var label = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if label.hasPrefix("OPTION ") { label.removeFirst(7) }
        label = label.trimmingCharacters(in: CharacterSet(charactersIn: " ().:"))
        if kind == .trueFalse {
            if label == "TRUE" { label = "T" }
            if label == "FALSE" { label = "F" }
            guard label == "T" || label == "F" else {
                throw invalid("Claude returned \(raw) for a true/false question.")
            }
            return label
        }
        let allowed = AnswerLabels.allowed(for: kind)
        guard allowed.numbers.contains(label) || allowed.letters.contains(label) else {
            throw invalid("Claude returned an unsupported option: \(raw)")
        }
        return label
    }

    private static func requireOneFamily(_ labels: [String], for kind: AnswerKind) throws {
        let allowed = AnswerLabels.allowed(for: kind)
        guard labels.allSatisfy(allowed.numbers.contains) || labels.allSatisfy(allowed.letters.contains) else {
            throw invalid("Claude mixed numbered and lettered options: \(labels.joined(separator: ", "))")
        }
    }

    /// Unique, one label family, in display order.
    static func validatedSelection(_ labels: [String], for kind: AnswerKind) throws -> [String] {
        var seen = Set<String>()
        let unique = labels.filter { seen.insert($0).inserted }
        if kind == .trueFalse { return unique }
        try requireOneFamily(unique, for: kind)
        return unique.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 10, n % 100) {
        case (_, 11...13): suffix = "th"
        case (1, _): suffix = "st"
        case (2, _): suffix = "nd"
        case (3, _): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }

    private static func extractJSONObject(from text: String) -> Data? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start <= end else { return nil }
        return String(text[start...end]).data(using: .utf8)
    }
}
