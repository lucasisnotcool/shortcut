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

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"
        ].joined(separator: ":")
        // Never let a parent Claude Code session leak into the child.
        environment.removeValue(forKey: "CLAUDECODE")
        environment.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        process.environment = environment

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
           let answer = answer(from: object) {
            return answer
        }
        if let object = root["result"] as? [String: Any],
           let answer = answer(from: object) {
            return answer
        }
        if let text = root["result"] as? String,
           let nestedData = extractJSONObject(from: text),
           let object = try? JSONSerialization.jsonObject(with: nestedData) as? [String: Any],
           let answer = answer(from: object) {
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

    private static func answer(from object: [String: Any]) -> WindowAnswer? {
        guard let option = (object["selected_option"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let explanation = object["explanation"] as? String else { return nil }
        return WindowAnswer(option: option.uppercased(), explanation: explanation)
    }

    private static func extractJSONObject(from text: String) -> Data? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start <= end else { return nil }
        return String(text[start...end]).data(using: .utf8)
    }
}
