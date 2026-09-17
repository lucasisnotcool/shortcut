import AppKit
import Foundation

/// Which model produced an assistant message. Saved with the conversation;
/// messages from before model routing have none and came from the CLI.
struct AnsweredBy: Codable, Equatable {
    var label: String
    var provider: ProviderKind
    /// Earlier models in the list were skipped or failed.
    var fellBack = false
    /// "GPT-5 · OpenAI: rate limited", for the tooltip.
    var skipped: [String] = []
}

/// A model as the router sees it: the entry plus what the main actor looked up.
struct RoutableModel {
    var entry: ModelEntry
    var key: String?
    /// Why it can't be tried (no key, no model id), or nil.
    var problem: String?
}

struct RoutedReply<Value> {
    var value: Value
    var answeredBy: AnsweredBy
}

/// The Claude CLI side of routing; `ClaudeService` in the app, a stub in tests.
protocol CLIModelRunner {
    func chat(text: String, images: [ClaudeImage], context: ContextSnapshot, model: String) async throws -> String
    func resetSession() async
}

/// Sends each request to the first model in the ranked list that can take
/// it, falling back down the list on errors. One request at a time, like
/// the single shared session it stands in for.
actor ModelRouter {
    private let cli: CLIModelRunner
    private let transport: HTTPTransport
    /// Models that failed recently are tried after the others until this passes.
    private var cooldowns: [ModelEntry: Date] = [:]
    private var queueTail: Task<Void, Never>?
    /// Seconds to wait before retrying a transient failure; tests use zero.
    var retryDelay: TimeInterval = 2

    static let maxHistoryTurns = 40
    static let tokensPerImage = 1_600

    init(cli: CLIModelRunner = ClaudeService(), transport: HTTPTransport = URLSessionTransport()) {
        self.cli = cli
        self.transport = transport
    }

    func setRetryDelay(_ delay: TimeInterval) { retryDelay = delay }

    // MARK: Requests

    func chat(history: [ChatMessage], text: String, images: [NSImage], context: ContextSnapshot,
              models: [RoutableModel]) async throws -> RoutedReply<String> {
        let converted = try images.map(ClaudeImage.init(image:))
        return try await serialized {
            try await self.route(models, history: history, text: text, images: converted, context: context)
        }
    }

    func answerQuestion(history: [ChatMessage], screenshot: URL, context: ContextSnapshot,
                        models: [RoutableModel]) async throws -> RoutedReply<WindowAnswer> {
        // JSON is requested in the reply rather than via a schema option, which
        // would add a tool on the CLI and break the prompt cache.
        let prompt = PromptSettings.windowCheck + "\n\n" + PromptSettings.windowCheckReplyFormat
        let image = try ClaudeImage(fileURL: screenshot)
        return try await serialized {
            let reply = try await self.route(models, history: history, text: prompt, images: [image], context: context)
            // A malformed answer is shown as is rather than retried elsewhere.
            let answer = try ClaudeOutputParser.windowAnswer(fromText: reply.value)
            return RoutedReply(value: answer, answeredBy: reply.answeredBy)
        }
    }

    /// Starts a new CLI session and forgets recent failures.
    func reset() async {
        cooldowns.removeAll()
        await cli.resetSession()
    }

    func clearCooldowns() {
        cooldowns.removeAll()
    }

    // MARK: Routing

    private func route(_ models: [RoutableModel], history: [ChatMessage], text: String, images: [ClaudeImage],
                       context: ContextSnapshot) async throws -> RoutedReply<String> {
        let now = Date()
        let enabled = models.filter(\.entry.isEnabled)
        guard !enabled.isEmpty else {
            throw AppError.processFailed("No models are switched on. Open Models… in the main window to add or enable one.")
        }
        // Cooling-down models keep their order but go after the rest.
        let ordered = enabled.filter { (cooldowns[$0.entry] ?? .distantPast) <= now }
            + enabled.filter { (cooldowns[$0.entry] ?? .distantPast) > now }

        var skipped: [String] = []
        var failures: [(entry: ModelEntry, error: Error)] = []
        for model in ordered {
            let entry = model.entry
            if !images.isEmpty, !entry.vision {
                skipped.append("\(entry.label): no image input")
                continue
            }
            if let problem = model.problem {
                skipped.append("\(entry.label): \(problem.lowercased())")
                continue
            }
            for attempt in 0..<2 {
                do {
                    let started = Date()
                    let reply = try await send(model, history: history, text: text, images: images, context: context)
                    cooldowns[entry] = nil
                    let elapsed = Date().timeIntervalSince(started)
                    appLog.info("\(entry.label, privacy: .public) answered in \(elapsed, format: .fixed(precision: 1))s — \(reply.usage ?? "no usage", privacy: .public)")
                    if !skipped.isEmpty {
                        appLog.notice("Fell back to \(entry.label, privacy: .public): \(skipped.joined(separator: "; "), privacy: .public)")
                    }
                    return RoutedReply(value: reply.text,
                                       answeredBy: AnsweredBy(label: entry.label, provider: entry.provider,
                                                              fellBack: !skipped.isEmpty, skipped: skipped))
                } catch {
                    let failure = Self.classify(error, provider: entry.provider)
                    appLog.error("\(entry.label, privacy: .public) failed (\(failure.shortReason, privacy: .public)): \(failure.message, privacy: .public)")
                    if attempt == 0, failure.isTransient, entry.provider != .claudeCLI {
                        let delay = min(failure.retryAfter ?? retryDelay, 8)
                        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                        continue
                    }
                    if failure.cooldown > 0 { cooldowns[entry] = Date().addingTimeInterval(failure.cooldown) }
                    skipped.append("\(entry.label): \(failure.shortReason)")
                    failures.append((entry, error))
                    break
                }
            }
        }

        // With a single model the teacher sees its own error, as before.
        if failures.count == 1, skipped.count == 1 { throw failures[0].error }
        if failures.isEmpty {
            let reason = images.isEmpty
                ? "No model is ready"
                : "No model that accepts images is ready"
            throw AppError.processFailed("\(reason). \(skipped.joined(separator: "; ")). Open Models… to fix this.")
        }
        let last = failures[failures.count - 1]
        throw AppError.processFailed("Every model failed (\(skipped.joined(separator: "; "))). Last error from \(last.entry.label): \(last.error.localizedDescription)")
    }

    private func send(_ model: RoutableModel, history: [ChatMessage], text: String, images: [ClaudeImage],
                      context: ContextSnapshot) async throws -> LLMReply {
        let entry = model.entry
        if entry.provider == .claudeCLI {
            let prompt = Self.cliCatchUp(history: history).map { $0 + text } ?? text
            let reply = try await cli.chat(text: prompt, images: images, context: context, model: entry.model)
            return LLMReply(text: reply, usage: nil)
        }
        guard let client = ModelCatalog.client(for: entry, key: model.key, transport: transport) else {
            throw ProviderError(kind: .notConfigured, message: "\(entry.label) has no client.")
        }
        var request = LLMRequest(
            system: Self.systemPrompt(context: context, entry: entry),
            turns: Self.turns(history: history) + [LLMTurn(role: .user, text: text, images: images)],
            reader: entry.tools && !context.readableDirectories.isEmpty
                ? ReferenceReader(directories: context.readableDirectories) : nil,
            webSearch: entry.webSearch && entry.provider.supportsWebSearch,
            maxOutputTokens: entry.maxOutputTokens,
            temperature: entry.temperature
        )
        request.turns = Self.normalized(request.turns)
        try Self.fit(&request, entry: entry)
        return try await client.complete(request)
    }

    static func classify(_ error: Error, provider: ProviderKind) -> ProviderError {
        if let error = error as? ProviderError { return error }
        if let error = error as? AppError {
            switch error {
            case .claudeNotFound:
                return ProviderError(kind: .notConfigured, message: error.localizedDescription)
            case .processFailed(let detail), .invalidResponse(let detail):
                let lower = detail.lowercased()
                if lower.contains("rate limit") || lower.contains("usage limit") || lower.contains("limit reached") {
                    return ProviderError(kind: .rateLimited, message: detail)
                }
                if lower.contains("did not respond within") { return ProviderError(kind: .timeout, message: detail) }
                if lower.contains("not logged in") || lower.contains("login") || lower.contains("credit balance") {
                    return ProviderError(kind: .auth, message: detail)
                }
                return ProviderError(kind: .server, message: detail)
            default:
                return ProviderError(kind: .server, message: error.localizedDescription)
            }
        }
        return ProviderError.classify(error)
    }

    // MARK: Prompt

    /// The CLI's system prompt plus a note on what this session can do.
    /// The documents stay first, so provider caches keep working.
    static func systemPrompt(context: ContextSnapshot, entry: ModelEntry) -> String {
        let base = context.documentsBlock.isEmpty
            ? PromptSettings.instructions
            : context.documentsBlock + "\n" + PromptSettings.instructions
        let canRead = entry.tools && !context.readableDirectories.isEmpty
        let canSearch = entry.webSearch && entry.provider.supportsWebSearch
        var lines = ["You are running as \(entry.model) through \(entry.provider.title), not through Claude Code. Earlier turns in this conversation may have been answered by other models."]
        lines.append(canRead
            ? "The Read tool takes file_path and optional pages (for example \"2-5\") and is limited to the reference folders."
            : "No Read tool is available: you cannot open on-demand files. If a question needs one, say so.")
        lines.append(canSearch
            ? "Web search is available for current or external information."
            : "WebSearch and WebFetch are not available: do not claim to have searched the web.")
        return base + "\n\n<session_setup>\n" + lines.joined(separator: "\n") + "\n</session_setup>\n"
    }

    /// The saved chat as text turns. Only the current message carries images.
    static func turns(history: [ChatMessage]) -> [LLMTurn] {
        history.suffix(maxHistoryTurns).map { message in
            switch message.role {
            case .user:
                return LLMTurn(role: .user, text: transcriptText(message))
            case .assistant:
                return LLMTurn(role: .assistant, text: transcriptText(message))
            }
        }
    }

    static func transcriptText(_ message: ChatMessage) -> String {
        switch message.role {
        case .user:
            if message.isWindowCheck { return "[Active-window check of an earlier screenshot, not repeated here]" }
            var text = message.promptText ?? message.text
            if !message.images.isEmpty {
                text += (text.isEmpty ? "" : "\n") + "[\(message.images.count) image\(message.images.count == 1 ? "" : "s") attached earlier, not repeated here]"
            }
            return text
        case .assistant:
            guard let answer = message.answer else { return message.text }
            return "\(answer.title)\n\(message.text)"
        }
    }

    /// Joins same-role neighbours (a question whose reply failed) and drops a
    /// leading reply, since the native APIs need alternating turns.
    static func normalized(_ turns: [LLMTurn]) -> [LLMTurn] {
        var result: [LLMTurn] = []
        for turn in turns {
            if result.isEmpty, turn.role == .assistant { continue }
            if var last = result.last, last.role == turn.role {
                last.text += "\n\n" + turn.text
                last.images += turn.images
                result[result.count - 1] = last
            } else {
                result.append(turn)
            }
        }
        return result
    }

    static func estimateTokens(_ request: LLMRequest) -> Int {
        ContextLibrary.estimateTokens(request.system)
            + request.turns.reduce(0) { $0 + ContextLibrary.estimateTokens($1.text) + $1.images.count * tokensPerImage }
    }

    /// Drops the oldest turns until the request fits the model's context, or
    /// fails so the router moves to a larger model.
    static func fit(_ request: inout LLMRequest, entry: ModelEntry) throws {
        guard let limit = entry.contextTokens, limit > 0 else { return }
        while estimateTokens(request) + entry.maxOutputTokens > limit, request.turns.count > 1 {
            request.turns.removeFirst()
            if request.turns.first?.role == .assistant { request.turns.removeFirst() }
        }
        let needed = estimateTokens(request) + entry.maxOutputTokens
        if needed > limit {
            throw ProviderError(kind: .contextTooLong,
                                message: "\(entry.label) holds \(limit.formatted()) tokens; the reference documents and this request need about \(needed.formatted()).")
        }
    }

    /// The CLI keeps its own session, so it misses turns other models
    /// answered since its last reply. Those are replayed as a preamble.
    static func cliCatchUp(history: [ChatMessage]) -> String? {
        let lastCLI = history.lastIndex { $0.role == .assistant && ($0.answeredBy == nil || $0.answeredBy?.provider == .claudeCLI) }
        let missed = history[(lastCLI.map { $0 + 1 } ?? 0)...]
        guard missed.contains(where: { $0.role == .assistant && $0.answeredBy.map { $0.provider != .claudeCLI } == true }) else {
            return nil
        }
        let lines = missed.suffix(maxHistoryTurns).map { message in
            let speaker = message.role == .user ? "Teacher" : "Assistant (\(message.answeredBy?.label ?? "another model"))"
            return "\(speaker): \(transcriptText(message))"
        }
        return "[Turns answered by other models while you were unavailable]\n" + lines.joined(separator: "\n\n")
            + "\n[End of those turns]\n\n"
    }

    // MARK: Queue

    private func serialized<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        let previous = queueTail
        let task = Task { () async throws -> T in
            await previous?.value
            return try await operation()
        }
        queueTail = Task { _ = try? await task.value }
        return try await task.value
    }
}
