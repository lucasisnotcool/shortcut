import AppKit
import Foundation

// MARK: - Shared types

/// One turn of the shared conversation, as sent to an API model.
struct LLMTurn: Equatable {
    enum Role: Equatable { case user, assistant }
    var role: Role
    var text: String
    var images: [ClaudeImage] = []
}

struct LLMRequest {
    var system: String
    var turns: [LLMTurn]
    /// Present when the model may open on-demand reference files.
    var reader: ReferenceReader?
    var webSearch = false
    var maxOutputTokens = 8_192
    var temperature: Double?
}

struct LLMReply {
    var text: String
    /// "input 1200 (cached 1000), output 90" for the log.
    var usage: String?
}

/// Why an API request failed, sorted by what the router should do next.
struct ProviderError: LocalizedError, Equatable {
    enum Kind: Equatable {
        case notConfigured
        case auth
        case notFound
        case rateLimited
        case quota
        case server
        case timeout
        case network
        case contextTooLong
        case badRequest
        case unsupportedInput
        case emptyReply
    }

    var kind: Kind
    var message: String
    var retryAfter: TimeInterval?

    var errorDescription: String? { message }

    /// Worth one more try on the same model.
    var isTransient: Bool { [.rateLimited, .server, .timeout, .network].contains(kind) }

    /// How long the router leaves the model alone after this failure.
    var cooldown: TimeInterval {
        switch kind {
        case .rateLimited, .server, .timeout, .network: return 60
        case .auth, .notFound, .quota, .notConfigured: return 600
        case .contextTooLong, .badRequest, .unsupportedInput, .emptyReply: return 0
        }
    }

    /// "rate limited", for the fallback summary.
    var shortReason: String {
        switch kind {
        case .notConfigured: return "not set up"
        case .auth: return "key rejected"
        case .notFound: return "model not found"
        case .rateLimited: return "rate limited"
        case .quota: return "out of credit"
        case .server: return "provider error"
        case .timeout: return "timed out"
        case .network: return "unreachable"
        case .contextTooLong: return "context too long"
        case .badRequest: return "request rejected"
        case .unsupportedInput: return "can't take this input"
        case .emptyReply: return "empty reply"
        }
    }

    static func classify(status: Int, body: Data, headers: [AnyHashable: Any] = [:]) -> ProviderError {
        let message = extractMessage(body) ?? HTTPURLResponse.localizedString(forStatusCode: status)
        let lower = message.lowercased()
        let retryAfter = (headers["Retry-After"] as? String ?? headers["retry-after"] as? String).flatMap(TimeInterval.init)
        let detail = "HTTP \(status): \(message)"
        let contextHints = ["context length", "context_length", "context window", "too long", "too many tokens",
                            "maximum context", "reduce the length", "exceeds the maximum", "prompt is too long"]
        if status == 413 || contextHints.contains(where: lower.contains) {
            return ProviderError(kind: .contextTooLong, message: detail)
        }
        switch status {
        case 401, 403: return ProviderError(kind: .auth, message: detail)
        case 402: return ProviderError(kind: .quota, message: detail)
        case 404: return ProviderError(kind: .notFound, message: detail)
        case 408, 504: return ProviderError(kind: .timeout, message: detail)
        case 429:
            if lower.contains("quota") || lower.contains("billing") || lower.contains("credit") {
                return ProviderError(kind: .quota, message: detail)
            }
            return ProviderError(kind: .rateLimited, message: detail, retryAfter: retryAfter)
        case 500...599: return ProviderError(kind: .server, message: detail, retryAfter: retryAfter)
        default:
            if lower.contains("image") && (lower.contains("support") || lower.contains("vision")) {
                return ProviderError(kind: .unsupportedInput, message: detail)
            }
            if lower.contains("credit balance") { return ProviderError(kind: .quota, message: detail) }
            return ProviderError(kind: .badRequest, message: detail)
        }
    }

    static func classify(_ error: Error) -> ProviderError {
        if let error = error as? ProviderError { return error }
        if let error = error as? URLError {
            switch error.code {
            case .timedOut: return ProviderError(kind: .timeout, message: "The request timed out.")
            case .cancelled: return ProviderError(kind: .network, message: "The request was cancelled.")
            default: return ProviderError(kind: .network, message: error.localizedDescription)
            }
        }
        return ProviderError(kind: .badRequest, message: error.localizedDescription)
    }

    /// `{"error": {"message": …}}`, `{"error": "…"}`, `{"message": …}` or a
    /// list of those (Gemini sometimes wraps errors in an array).
    static func extractMessage(_ body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) else {
            let text = String(decoding: body.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        let root = (object as? [[String: Any]])?.first ?? object as? [String: Any]
        if let error = root?["error"] as? [String: Any], let message = error["message"] as? String { return message }
        if let error = root?["error"] as? String { return error }
        if let message = root?["message"] as? String { return message }
        if let detail = root?["detail"] as? String { return detail }
        return nil
    }
}

/// Sends requests; tests substitute a scripted one.
protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionTransport: HTTPTransport {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 240
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError(kind: .network, message: "No HTTP response from \(request.url?.host ?? "the server").")
        }
        return (data, http)
    }
}

protocol LLMClient {
    func complete(_ request: LLMRequest) async throws -> LLMReply
}

/// Shared plumbing for the HTTP clients.
struct APIConnection {
    let entry: ModelEntry
    let key: String?
    let transport: HTTPTransport

    /// Tool rounds before giving up (each round can open several files).
    static let maxToolRounds = 8

    func url(_ path: String) throws -> URL {
        guard let url = URL(string: entry.resolvedBaseURL + path), url.scheme != nil, url.host != nil else {
            throw ProviderError(kind: .notConfigured, message: "\(entry.label) has no valid server address.")
        }
        return url
    }

    func post(_ path: String, body: [String: Any], headers: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: try url(path))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(request, headers: headers)
    }

    func get(_ path: String, headers: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: try url(path))
        request.timeoutInterval = 20
        return try await send(request, headers: headers)
    }

    private func send(_ request: URLRequest, headers: [String: String]) async throws -> [String: Any] {
        var request = request
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        for (name, value) in entry.headerPairs { request.setValue(value, forHTTPHeaderField: name) }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw ProviderError.classify(error)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ProviderError.classify(status: response.statusCode, body: data, headers: response.allHeaderFields)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError(kind: .server, message: "\(entry.label) returned something other than JSON.")
        }
        return object
    }

    func requireKey() throws -> String {
        guard let key, !key.isEmpty else {
            throw ProviderError(kind: .notConfigured, message: "No API key saved for \(entry.provider.title).")
        }
        return key
    }

    static func base64(_ image: ClaudeImage) -> String { image.data.base64EncodedString() }

    static func dataURL(_ image: ClaudeImage) -> String { "data:\(image.mediaType);base64,\(base64(image))" }

    static func nonEmpty(_ text: String, images: [ClaudeImage]) -> String {
        text.isEmpty ? (images.isEmpty ? "(empty message)" : "(See the attached image.)") : text
    }

    static func finish(_ text: String, usage: String?, entry: ModelEntry) throws -> LLMReply {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProviderError(kind: .emptyReply, message: "\(entry.label) returned an empty reply.")
        }
        return LLMReply(text: trimmed, usage: usage)
    }

    static func toolLimitError(_ entry: ModelEntry) -> ProviderError {
        ProviderError(kind: .badRequest, message: "\(entry.label) kept opening files without answering.")
    }

    /// Whether a rejected request is worth repeating without tools.
    static func rejectedTools(_ error: Error) -> Bool {
        guard let error = error as? ProviderError, error.kind == .badRequest else { return false }
        let lower = error.message.lowercased()
        return lower.contains("tool") || lower.contains("function")
    }
}

// MARK: - Anthropic Messages API

struct AnthropicClient: LLMClient {
    let connection: APIConnection
    static let version = "2023-06-01"

    func complete(_ request: LLMRequest) async throws -> LLMReply {
        let key = try connection.requireKey()
        let headers = ["x-api-key": key, "anthropic-version": Self.version]
        var messages: [[String: Any]] = request.turns.map { turn in
            var content: [[String: Any]] = turn.images.map(Self.imageBlock)
            content.append(["type": "text", "text": APIConnection.nonEmpty(turn.text, images: turn.images)])
            return ["role": turn.role == .user ? "user" : "assistant", "content": content]
        }
        var tools: [[String: Any]] = []
        if request.reader != nil {
            tools.append(["name": ReferenceReader.toolName, "description": ReferenceReader.toolDescription,
                          "input_schema": ReferenceReader.parameterSchema])
        }
        if request.webSearch {
            tools.append(["type": "web_search_20250305", "name": "web_search", "max_uses": 5])
        }

        var inputTokens = 0, cachedTokens = 0, cacheWrites = 0, outputTokens = 0
        for _ in 0..<APIConnection.maxToolRounds {
            var body: [String: Any] = [
                "model": connection.entry.model,
                "max_tokens": request.maxOutputTokens,
                // The documents are the long, stable prefix: cache them.
                "system": [["type": "text", "text": request.system, "cache_control": ["type": "ephemeral"]]],
                "messages": messages
            ]
            if !tools.isEmpty { body["tools"] = tools }
            if let temperature = request.temperature { body["temperature"] = temperature }
            let response = try await connection.post("/v1/messages", body: body, headers: headers)

            if let usage = response["usage"] as? [String: Any] {
                inputTokens += usage["input_tokens"] as? Int ?? 0
                cachedTokens += usage["cache_read_input_tokens"] as? Int ?? 0
                cacheWrites += usage["cache_creation_input_tokens"] as? Int ?? 0
                outputTokens += usage["output_tokens"] as? Int ?? 0
            }
            let content = response["content"] as? [[String: Any]] ?? []
            let stopReason = response["stop_reason"] as? String
            let toolUses = content.filter { $0["type"] as? String == "tool_use" }

            if stopReason == "pause_turn" {
                // A long server-side search: send the turn back unchanged to continue.
                messages.append(["role": "assistant", "content": content])
                continue
            }
            if stopReason == "tool_use", !toolUses.isEmpty, let reader = request.reader {
                messages.append(["role": "assistant", "content": content])
                var results: [[String: Any]] = []
                for use in toolUses {
                    let input = use["input"] as? [String: Any] ?? [:]
                    let output = await reader.run(input)
                    var blocks: [[String: Any]] = [["type": "text", "text": output.text]]
                    blocks += output.images.map(Self.imageBlock)
                    results.append(["type": "tool_result", "tool_use_id": use["id"] as? String ?? "",
                                    "content": blocks, "is_error": output.isError])
                }
                messages.append(["role": "user", "content": results])
                continue
            }
            let text = content.filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }.joined()
            if stopReason == "refusal", text.isEmpty {
                throw ProviderError(kind: .emptyReply, message: "\(connection.entry.label) declined to answer.")
            }
            let usage = "input \(inputTokens), cache read \(cachedTokens), cache write \(cacheWrites), output \(outputTokens)"
            return try APIConnection.finish(text, usage: usage, entry: connection.entry)
        }
        throw APIConnection.toolLimitError(connection.entry)
    }

    static func imageBlock(_ image: ClaudeImage) -> [String: Any] {
        ["type": "image", "source": ["type": "base64", "media_type": image.mediaType, "data": APIConnection.base64(image)]]
    }
}

// MARK: - OpenAI Chat Completions (and compatible servers)

struct OpenAIClient: LLMClient {
    let connection: APIConnection

    private var provider: ProviderKind { connection.entry.provider }

    var headers: [String: String] {
        var headers: [String: String] = [:]
        if let key = connection.key, !key.isEmpty {
            if provider == .azureOpenAI {
                headers["api-key"] = key
            } else {
                headers["Authorization"] = "Bearer \(key)"
            }
        }
        if provider == .openRouter {
            headers["HTTP-Referer"] = "https://github.com/lucasisnotcool/shortcut"
            headers["X-Title"] = "Shortcut"
        }
        return headers
    }

    func complete(_ request: LLMRequest) async throws -> LLMReply {
        if provider.requiresKey { _ = try connection.requireKey() }
        do {
            return try await run(request)
        } catch where request.reader != nil && APIConnection.rejectedTools(error) {
            appLog.notice("\(connection.entry.label, privacy: .public) rejected tools; retrying without them")
            var plain = request
            plain.reader = nil
            return try await run(plain)
        }
    }

    private func run(_ request: LLMRequest) async throws -> LLMReply {
        var messages: [[String: Any]] = [["role": "system", "content": request.system]]
        messages += request.turns.map { turn in
            ["role": turn.role == .user ? "user" : "assistant", "content": Self.content(turn.text, turn.images)]
        }
        var inputTokens = 0, cachedTokens = 0, outputTokens = 0
        for _ in 0..<APIConnection.maxToolRounds {
            var body: [String: Any] = ["model": connection.entry.model, "messages": messages]
            // OpenAI's newer models only take max_completion_tokens; most compatible servers only max_tokens.
            if provider == .openAI || provider == .azureOpenAI {
                body["max_completion_tokens"] = request.maxOutputTokens
            } else {
                body["max_tokens"] = request.maxOutputTokens
            }
            if let temperature = request.temperature { body["temperature"] = temperature }
            if request.reader != nil {
                body["tools"] = [["type": "function", "function": [
                    "name": ReferenceReader.toolName,
                    "description": ReferenceReader.toolDescription,
                    "parameters": ReferenceReader.parameterSchema
                ]]]
            }
            if request.webSearch, provider == .openRouter {
                body["plugins"] = [["id": "web"]]
            }
            let response = try await connection.post("/chat/completions", body: body, headers: headers)
            if let usage = response["usage"] as? [String: Any] {
                inputTokens += usage["prompt_tokens"] as? Int ?? 0
                outputTokens += usage["completion_tokens"] as? Int ?? 0
                cachedTokens += (usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0
            }
            guard let choice = (response["choices"] as? [[String: Any]])?.first,
                  let message = choice["message"] as? [String: Any] else {
                throw ProviderError(kind: .server, message: "\(connection.entry.label) returned no choices.")
            }
            let calls = message["tool_calls"] as? [[String: Any]] ?? []
            if !calls.isEmpty, let reader = request.reader {
                var assistant: [String: Any] = ["role": "assistant", "tool_calls": calls]
                assistant["content"] = message["content"] as? String ?? NSNull()
                messages.append(assistant)
                var images: [ClaudeImage] = []
                for call in calls {
                    let function = call["function"] as? [String: Any] ?? [:]
                    let arguments = Self.arguments(function["arguments"])
                    let output = await reader.run(arguments)
                    images += output.images
                    let note = output.images.isEmpty ? "" : "\n(The page images follow in the next message.)"
                    messages.append(["role": "tool", "tool_call_id": call["id"] as? String ?? "", "content": output.text + note])
                }
                // Tool messages carry text only; images go in a user message.
                if !images.isEmpty {
                    messages.append(["role": "user", "content": Self.content("Images returned by Read:", images)])
                }
                continue
            }
            let text = Self.text(message["content"])
            if text.isEmpty, let refusal = message["refusal"] as? String {
                throw ProviderError(kind: .emptyReply, message: "\(connection.entry.label) declined: \(refusal)")
            }
            let usage = "input \(inputTokens), cached \(cachedTokens), output \(outputTokens)"
            return try APIConnection.finish(text, usage: usage, entry: connection.entry)
        }
        throw APIConnection.toolLimitError(connection.entry)
    }

    /// Plain text when there are no images, which text-only servers require.
    static func content(_ text: String, _ images: [ClaudeImage]) -> Any {
        let text = APIConnection.nonEmpty(text, images: images)
        guard !images.isEmpty else { return text }
        var parts: [[String: Any]] = images.map {
            ["type": "image_url", "image_url": ["url": APIConnection.dataURL($0), "detail": "high"]]
        }
        parts.append(["type": "text", "text": text])
        return parts
    }

    static func text(_ content: Any?) -> String {
        if let text = content as? String { return text }
        if let parts = content as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined()
        }
        return ""
    }

    static func arguments(_ value: Any?) -> [String: Any] {
        if let object = value as? [String: Any] { return object }
        if let text = value as? String, let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        return [:]
    }
}

// MARK: - Gemini generateContent

struct GeminiClient: LLMClient {
    let connection: APIConnection

    func complete(_ request: LLMRequest) async throws -> LLMReply {
        do {
            return try await run(request, search: request.webSearch)
        } catch where request.webSearch && request.reader != nil && APIConnection.rejectedTools(error) {
            // Some Gemini models can't combine Google Search with function calls.
            appLog.notice("\(connection.entry.label, privacy: .public) rejected search with tools; retrying without search")
            return try await run(request, search: false)
        }
    }

    private func run(_ request: LLMRequest, search: Bool) async throws -> LLMReply {
        let key = try connection.requireKey()
        let headers = ["x-goog-api-key": key]
        var contents: [[String: Any]] = request.turns.map { turn in
            var parts: [[String: Any]] = turn.images.map(Self.imagePart)
            parts.append(["text": APIConnection.nonEmpty(turn.text, images: turn.images)])
            return ["role": turn.role == .user ? "user" : "model", "parts": parts]
        }
        var tools: [[String: Any]] = []
        if request.reader != nil {
            tools.append(["functionDeclarations": [[
                "name": ReferenceReader.toolName,
                "description": ReferenceReader.toolDescription,
                "parameters": ReferenceReader.parameterSchema
            ]]])
        }
        if search { tools.append(["google_search": [String: Any]()]) }
        var config: [String: Any] = ["maxOutputTokens": request.maxOutputTokens]
        if let temperature = request.temperature { config["temperature"] = temperature }

        let model = connection.entry.model.hasPrefix("models/") ? String(connection.entry.model.dropFirst(7)) : connection.entry.model
        let path = "/v1beta/models/\(model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model):generateContent"
        var inputTokens = 0, cachedTokens = 0, outputTokens = 0
        for _ in 0..<APIConnection.maxToolRounds {
            var body: [String: Any] = [
                "systemInstruction": ["parts": [["text": request.system]]],
                "contents": contents,
                "generationConfig": config
            ]
            if !tools.isEmpty { body["tools"] = tools }
            let response = try await connection.post(path, body: body, headers: headers)
            if let usage = response["usageMetadata"] as? [String: Any] {
                inputTokens += usage["promptTokenCount"] as? Int ?? 0
                cachedTokens += usage["cachedContentTokenCount"] as? Int ?? 0
                outputTokens += usage["candidatesTokenCount"] as? Int ?? 0
            }
            guard let candidate = (response["candidates"] as? [[String: Any]])?.first else {
                let reason = (response["promptFeedback"] as? [String: Any])?["blockReason"] as? String
                throw ProviderError(kind: .emptyReply, message: "\(connection.entry.label) returned no answer\(reason.map { " (blocked: \($0))" } ?? "").")
            }
            let content = candidate["content"] as? [String: Any] ?? [:]
            let parts = content["parts"] as? [[String: Any]] ?? []
            let calls = parts.compactMap { $0["functionCall"] as? [String: Any] }
            if !calls.isEmpty, let reader = request.reader {
                // Sent back as-is: the parts carry thought signatures Gemini requires.
                contents.append(["role": "model", "parts": parts])
                var responses: [[String: Any]] = []
                var images: [ClaudeImage] = []
                for call in calls {
                    let output = await reader.run(call["args"] as? [String: Any] ?? [:])
                    images += output.images
                    var reply: [String: Any] = ["name": call["name"] as? String ?? ReferenceReader.toolName,
                                                "response": ["content": output.text]]
                    if let id = call["id"] { reply["id"] = id }
                    responses.append(["functionResponse": reply])
                }
                contents.append(["role": "user", "parts": responses + images.map(Self.imagePart)])
                continue
            }
            let text = parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
            if text.isEmpty, let reason = candidate["finishReason"] as? String, reason != "STOP" {
                throw ProviderError(kind: .emptyReply, message: "\(connection.entry.label) stopped without an answer (\(reason)).")
            }
            let usage = "input \(inputTokens), cached \(cachedTokens), output \(outputTokens)"
            return try APIConnection.finish(text, usage: usage, entry: connection.entry)
        }
        throw APIConnection.toolLimitError(connection.entry)
    }

    static func imagePart(_ image: ClaudeImage) -> [String: Any] {
        ["inline_data": ["mime_type": image.mediaType, "data": APIConnection.base64(image)]]
    }
}

// MARK: - Ollama native chat

/// Ollama's own endpoint, because its OpenAI-compatible one can't set the
/// context size, and the 4k default silently truncates the documents.
struct OllamaClient: LLMClient {
    let connection: APIConnection

    func complete(_ request: LLMRequest) async throws -> LLMReply {
        do {
            return try await run(request)
        } catch where request.reader != nil && APIConnection.rejectedTools(error) {
            appLog.notice("\(connection.entry.label, privacy: .public) does not support tools; retrying without them")
            var plain = request
            plain.reader = nil
            return try await run(plain)
        }
    }

    private func run(_ request: LLMRequest) async throws -> LLMReply {
        var messages: [[String: Any]] = [["role": "system", "content": request.system]]
        messages += request.turns.map(Self.message)
        let context = try await contextSize(for: request)
        var options: [String: Any] = ["num_ctx": context, "num_predict": request.maxOutputTokens]
        if let temperature = request.temperature { options["temperature"] = temperature }

        var inputTokens = 0, outputTokens = 0
        for _ in 0..<APIConnection.maxToolRounds {
            var body: [String: Any] = ["model": connection.entry.model, "messages": messages,
                                       "stream": false, "options": options]
            if request.reader != nil {
                body["tools"] = [["type": "function", "function": [
                    "name": ReferenceReader.toolName,
                    "description": ReferenceReader.toolDescription,
                    "parameters": ReferenceReader.parameterSchema
                ]]]
            }
            let response = try await connection.post("/api/chat", body: body, headers: [:])
            inputTokens += response["prompt_eval_count"] as? Int ?? 0
            outputTokens += response["eval_count"] as? Int ?? 0
            let message = response["message"] as? [String: Any] ?? [:]
            let calls = message["tool_calls"] as? [[String: Any]] ?? []
            if !calls.isEmpty, let reader = request.reader {
                messages.append(["role": "assistant", "content": message["content"] as? String ?? "", "tool_calls": calls])
                var images: [ClaudeImage] = []
                for call in calls {
                    let function = call["function"] as? [String: Any] ?? [:]
                    let output = await reader.run(OpenAIClient.arguments(function["arguments"]))
                    images += output.images
                    messages.append(["role": "tool", "content": output.text,
                                     "tool_name": function["name"] as? String ?? ReferenceReader.toolName])
                }
                if !images.isEmpty {
                    messages.append(Self.message(LLMTurn(role: .user, text: "Images returned by Read:", images: images)))
                }
                continue
            }
            let usage = "input \(inputTokens), output \(outputTokens), num_ctx \(context)"
            return try APIConnection.finish(message["content"] as? String ?? "", usage: usage, entry: connection.entry)
        }
        throw APIConnection.toolLimitError(connection.entry)
    }

    static func message(_ turn: LLMTurn) -> [String: Any] {
        var message: [String: Any] = ["role": turn.role == .user ? "user" : "assistant",
                                      "content": APIConnection.nonEmpty(turn.text, images: turn.images)]
        if !turn.images.isEmpty { message["images"] = turn.images.map(APIConnection.base64) }
        return message
    }

    /// Enough for the prompt and the reply, capped at what the model supports.
    private func contextSize(for request: LLMRequest) async throws -> Int {
        var limit = connection.entry.contextTokens
        if limit == nil {
            limit = (try? await ModelCatalog.ollamaDetails(connection, model: connection.entry.model))?.context
        }
        let needed = ModelRouter.estimateTokens(request) + request.maxOutputTokens + 1_024
        let cap = limit ?? 32_768
        if needed > cap {
            throw ProviderError(kind: .contextTooLong,
                                message: "\(connection.entry.label) holds \(cap.formatted()) tokens; this request needs about \(needed.formatted()).")
        }
        return min(cap, max(8_192, needed))
    }
}

// MARK: - Model lists

struct DiscoveredModel: Identifiable, Hashable {
    var id: String
    var name: String?
    var context: Int?
    var vision: Bool?
    var tools: Bool?
}

/// Fetches what a provider offers, for the model picker.
enum ModelCatalog {
    static let claudeAliases = ["opus[1m]", "opus", "sonnet[1m]", "sonnet", "haiku"]

    static func client(for entry: ModelEntry, key: String?, transport: HTTPTransport = URLSessionTransport()) -> LLMClient? {
        let connection = APIConnection(entry: entry, key: key, transport: transport)
        switch entry.provider.api {
        case .claudeCLI: return nil
        case .anthropic: return AnthropicClient(connection: connection)
        case .gemini: return GeminiClient(connection: connection)
        case .openAI: return OpenAIClient(connection: connection)
        case .ollama: return OllamaClient(connection: connection)
        }
    }

    static func list(for entry: ModelEntry, key: String?, transport: HTTPTransport = URLSessionTransport()) async throws -> [DiscoveredModel] {
        let connection = APIConnection(entry: entry, key: key, transport: transport)
        switch entry.provider.api {
        case .claudeCLI:
            return claudeAliases.map { DiscoveredModel(id: $0, context: $0.hasSuffix("[1m]") ? 1_000_000 : 200_000, vision: true, tools: true) }
        case .anthropic:
            let key = try connection.requireKey()
            let response = try await connection.get("/v1/models?limit=1000",
                                                     headers: ["x-api-key": key, "anthropic-version": AnthropicClient.version])
            return (response["data"] as? [[String: Any]] ?? []).compactMap { item in
                guard let id = item["id"] as? String else { return nil }
                return DiscoveredModel(id: id, name: item["display_name"] as? String,
                                       context: item["max_input_tokens"] as? Int, vision: true, tools: true)
            }
        case .gemini:
            let key = try connection.requireKey()
            let response = try await connection.get("/v1beta/models?pageSize=1000", headers: ["x-goog-api-key": key])
            return (response["models"] as? [[String: Any]] ?? []).compactMap { item in
                guard let name = item["name"] as? String,
                      (item["supportedGenerationMethods"] as? [String] ?? []).contains("generateContent") else { return nil }
                let id = name.hasPrefix("models/") ? String(name.dropFirst(7)) : name
                return DiscoveredModel(id: id, name: item["displayName"] as? String,
                                       context: item["inputTokenLimit"] as? Int, vision: true, tools: true)
            }
        case .openAI:
            let response = try await connection.get("/models", headers: OpenAIClient(connection: connection).headers)
            return (response["data"] as? [[String: Any]] ?? []).compactMap { item in
                guard let id = item["id"] as? String else { return nil }
                let architecture = item["architecture"] as? [String: Any]
                let modalities = architecture?["input_modalities"] as? [String]
                let parameters = item["supported_parameters"] as? [String]
                return DiscoveredModel(id: id, name: item["name"] as? String,
                                       context: item["context_length"] as? Int ?? item["context_window"] as? Int,
                                       vision: modalities.map { $0.contains("image") },
                                       tools: parameters.map { $0.contains("tools") })
            }
        case .ollama:
            let response = try await connection.get("/api/tags", headers: [:])
            return (response["models"] as? [[String: Any]] ?? []).compactMap { item in
                (item["name"] as? String ?? item["model"] as? String).map { DiscoveredModel(id: $0) }
            }
        }
    }

    /// Vision, tool support and context length from `/api/show`.
    static func ollamaDetails(_ connection: APIConnection, model: String) async throws -> DiscoveredModel {
        let response = try await connection.post("/api/show", body: ["model": model], headers: [:])
        let capabilities = response["capabilities"] as? [String]
        let info = response["model_info"] as? [String: Any] ?? [:]
        let context = info.first { $0.key.hasSuffix(".context_length") }?.value as? Int
        return DiscoveredModel(id: model, context: context,
                               vision: capabilities.map { $0.contains("vision") },
                               tools: capabilities.map { $0.contains("tools") })
    }

    static func details(for entry: ModelEntry, model: String, key: String?, transport: HTTPTransport = URLSessionTransport()) async -> DiscoveredModel? {
        guard entry.provider.api == .ollama else { return nil }
        return try? await ollamaDetails(APIConnection(entry: entry, key: key, transport: transport), model: model)
    }

    /// A tiny real request: text, plus a small image when vision is on.
    static func test(_ entry: ModelEntry, key: String?, transport: HTTPTransport = URLSessionTransport()) async throws -> String {
        guard let client = client(for: entry, key: key, transport: transport) else {
            throw ProviderError(kind: .notConfigured, message: "Use the Claude CLI status instead.")
        }
        var turn = LLMTurn(role: .user, text: "Reply with exactly the word: ok")
        if entry.vision, let image = try? ClaudeImage(image: testImage()) {
            turn.images = [image]
            turn.text = "An image is attached only to check that images are accepted. Reply with exactly the word: ok"
        }
        let request = LLMRequest(system: "You are a connection test.", turns: [turn], maxOutputTokens: 256, temperature: nil)
        let reply = try await client.complete(request)
        return reply.text
    }

    private static func testImage() -> NSImage {
        NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            NSColor.black.setFill(); rect.insetBy(dx: 16, dy: 16).fill()
            return true
        }
    }
}
