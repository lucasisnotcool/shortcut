import AppKit
import Foundation
import Testing
@testable import AnswerCircle

// MARK: - Fakes

/// Replies from a script, in order, and records every request.
final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [(Int, Any)]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [(Int, Any)]) { self.replies = replies }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, body) = lock.withLock { () -> (Int, Any) in
            requests.append(request)
            return replies.isEmpty ? (500, ["error": ["message": "script exhausted"]]) : replies.removeFirst()
        }
        let data = try JSONSerialization.data(withJSONObject: body)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }

    var bodies: [[String: Any]] {
        lock.withLock {
            requests.compactMap { $0.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
        }
    }
}

final class StubCLI: CLIModelRunner, @unchecked Sendable {
    var reply: Result<String, Error>
    private(set) var prompts: [String] = []
    init(_ reply: Result<String, Error>) { self.reply = reply }
    func chat(text: String, images: [ClaudeImage], context: ContextSnapshot, model: String) async throws -> String {
        prompts.append(text)
        return try reply.get()
    }
    func resetSession() async {}
}

private func entry(_ provider: ProviderKind, model: String = "m", vision: Bool = true, tools: Bool = false) -> ModelEntry {
    var entry = ModelEntry(provider: provider, model: model)
    entry.vision = vision
    entry.tools = tools
    entry.webSearch = false
    return entry
}

private func routable(_ entry: ModelEntry, key: String? = "k") -> RoutableModel {
    RoutableModel(entry: entry, key: key, problem: nil)
}

private func openAIReply(_ text: String) -> [String: Any] {
    ["choices": [["message": ["role": "assistant", "content": text]]], "usage": ["prompt_tokens": 10, "completion_tokens": 2]]
}

private func anthropicReply(_ text: String) -> [String: Any] {
    ["content": [["type": "text", "text": text]], "stop_reason": "end_turn", "usage": ["input_tokens": 5, "output_tokens": 1]]
}

private func smallImage() -> NSImage {
    NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
        NSColor.gray.setFill(); rect.fill(); return true
    }
}

// MARK: - Store

@Test @MainActor func modelStoreStartsWithClaudeCodeAndAppendsToBottom() throws {
    let suite = "ModelStoreTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let store = ModelStore(defaults: defaults, keys: MemoryKeyStore())
    #expect(store.entries.map(\.provider) == [.claudeCLI])
    #expect(store.entries[0].model == "opus[1m]")
    #expect(store.entries[0].label == "Opus · 1M context · Claude Code")
    store.entries[0].model = "sonnet"
    #expect(store.entries[0].displayName == "Sonnet")
    store.entries[0].model = "opus[1m]"

    store.add(.openAI)
    store.add(.ollama)
    #expect(store.entries.map(\.provider) == [.claudeCLI, .openAI, .ollama])

    store.move(from: IndexSet(integer: 2), to: 0)
    #expect(store.entries.map(\.provider) == [.ollama, .claudeCLI, .openAI])

    let reloaded = ModelStore(defaults: defaults, keys: MemoryKeyStore())
    #expect(reloaded.entries == store.entries)
}

@Test @MainActor func keysAreSharedPerProviderExceptCustom() {
    let keys = MemoryKeyStore()
    let store = ModelStore(defaults: nil, keys: keys)
    let first = store.add(.openAI)
    let second = store.add(.openAI)
    #expect(store.setupProblem(first) == "No API key")
    store.setKey("  sk-test \n", for: first)
    #expect(store.key(for: second) == "sk-test")
    #expect(store.setupProblem(second) == nil)

    let custom = store.add(.custom)
    #expect(store.setupProblem(custom) == "No model id")
    store.setKey("secret", for: custom)
    store.remove(custom.id)
    #expect(keys.read(account: custom.keychainAccount) == nil)
    // Removing one OpenAI model keeps the shared key.
    store.remove(first.id)
    #expect(store.key(for: second) == "sk-test")
    // Local servers need no key, but a model id.
    var local = store.add(.ollama)
    #expect(store.setupProblem(local) == "No model id")
    local.model = "gemma3"
    #expect(store.setupProblem(local) == nil)
}

@Test func modelEntryDecodesOlderShapes() throws {
    let id = UUID()
    let json = #"{"id":"\#(id.uuidString)","provider":"ollama","model":"llava"}"#
    let decoded = try JSONDecoder().decode(ModelEntry.self, from: Data(json.utf8))
    #expect(decoded.id == id)
    #expect(decoded.isEnabled)
    #expect(decoded.tools)
    #expect(decoded.maxOutputTokens == 8_192)
    #expect(decoded.resolvedBaseURL == "http://localhost:11434")
}

// MARK: - Errors

@Test func providerErrorsAreClassified() {
    func kind(_ status: Int, _ message: String) -> ProviderError.Kind {
        ProviderError.classify(status: status, body: Data(#"{"error":{"message":"\#(message)"}}"#.utf8)).kind
    }
    #expect(kind(401, "invalid x-api-key") == .auth)
    #expect(kind(404, "model not found") == .notFound)
    #expect(kind(429, "Rate limit reached") == .rateLimited)
    #expect(kind(429, "You exceeded your current quota") == .quota)
    #expect(kind(529, "Overloaded") == .server)
    #expect(kind(400, "prompt is too long: 250000 tokens > 200000 maximum") == .contextTooLong)
    #expect(kind(400, "This model does not support image input") == .unsupportedInput)
    #expect(kind(400, "Your credit balance is too low") == .quota)
    #expect(kind(400, "bad field") == .badRequest)
    #expect(ProviderError.classify(URLError(.timedOut)).kind == .timeout)
    #expect(ProviderError.classify(URLError(.cannotConnectToHost)).kind == .network)
    #expect(ProviderError.extractMessage(Data(#"[{"error":{"message":"gemini says no"}}]"#.utf8)) == "gemini says no")
}

// MARK: - Routing

@Test func fallsBackDownTheListAndSaysWho() async throws {
    let transport = ScriptedTransport([
        (500, ["error": ["message": "boom"]]),
        (503, ["error": ["message": "still down"]]),
        (200, anthropicReply("From Anthropic"))
    ])
    let cli = StubCLI(.failure(AppError.processFailed("Claude AI usage limit reached")))
    let router = ModelRouter(cli: cli, transport: transport)
    await router.setRetryDelay(0)
    let models = [routable(entry(.claudeCLI, model: "opus[1m]"), key: nil), routable(entry(.openAI)), routable(entry(.anthropic))]

    let reply = try await router.chat(history: [], text: "Hi", images: [], context: ContextSnapshot(), models: models)
    #expect(reply.value == "From Anthropic")
    #expect(reply.answeredBy.provider == .anthropic)
    #expect(reply.answeredBy.fellBack)
    #expect(reply.answeredBy.skipped.count == 2)
    #expect(reply.answeredBy.skipped[0].contains("rate limited"))
    // The OpenAI model was retried once before moving on.
    #expect(transport.requests.count == 3)
    #expect(cli.prompts == ["Hi"])
}

@Test func cooledDownModelsAreTriedLast() async throws {
    let transport = ScriptedTransport([
        (401, ["error": ["message": "bad key"]]),
        (200, openAIReply("second")),
        (200, openAIReply("second again"))
    ])
    let router = ModelRouter(cli: StubCLI(.success("")), transport: transport)
    await router.setRetryDelay(0)
    let first = entry(.anthropic)
    let second = entry(.openAI)
    let models = [routable(first), routable(second)]
    let one = try await router.chat(history: [], text: "a", images: [], context: ContextSnapshot(), models: models)
    #expect(one.answeredBy.provider == .openAI)
    let two = try await router.chat(history: [], text: "b", images: [], context: ContextSnapshot(), models: models)
    #expect(two.value == "second again")
    #expect(!two.answeredBy.fellBack)
    #expect(transport.requests.count == 3)

    await router.clearCooldowns()
}

@Test func windowChecksSkipTextOnlyModels() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("shot-\(UUID().uuidString).png")
    let rep = NSBitmapImageRep(data: smallImage().tiffRepresentation!)!
    try rep.representation(using: .png, properties: [:])!.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let json = #"{"question":"Q1","question_type":"single","options":[{"option":"A","is_answer":false,"reason":"no"},{"option":"B","is_answer":true,"reason":"yes"}],"explanation":"B."}"#
    let transport = ScriptedTransport([(200, openAIReply("```json\n\(json)\n```"))])
    let router = ModelRouter(cli: StubCLI(.success("")), transport: transport)
    let models = [routable(entry(.deepSeek, vision: false)), routable(entry(.openAI))]
    let reply = try await router.answerQuestion(history: [], screenshot: url, context: ContextSnapshot(), models: models)
    #expect(reply.value.tag == AnswerTag(kind: .single, values: ["B"], question: "Q1"))
    #expect(reply.answeredBy.skipped == ["m · DeepSeek: no image input"])
    let body = try #require(transport.bodies.first)
    let messages = try #require(body["messages"] as? [[String: Any]])
    let parts = try #require(messages.last?["content"] as? [[String: Any]])
    #expect(parts.first?["type"] as? String == "image_url")
    #expect(((parts.first?["image_url"] as? [String: Any])?["url"] as? String)?.hasPrefix("data:image/png;base64,") == true)
}

@Test func singleModelShowsItsOwnError() async throws {
    let transport = ScriptedTransport([(401, ["error": ["message": "invalid x-api-key"]])])
    let router = ModelRouter(cli: StubCLI(.success("")), transport: transport)
    await #expect {
        _ = try await router.chat(history: [], text: "Hi", images: [], context: ContextSnapshot(), models: [routable(entry(.anthropic))])
    } throws: { error in
        (error as? ProviderError)?.message == "HTTP 401: invalid x-api-key"
    }
}

@Test func nothingReadyExplainsWhy() async throws {
    let router = ModelRouter(cli: StubCLI(.success("")), transport: ScriptedTransport([]))
    var off = entry(.openAI)
    off.isEnabled = false
    await #expect(throws: AppError.self) {
        _ = try await router.chat(history: [], text: "Hi", images: [], context: ContextSnapshot(), models: [routable(off)])
    }
    let missingKey = RoutableModel(entry: entry(.openAI), key: nil, problem: "No API key")
    do {
        _ = try await router.chat(history: [], text: "Hi", images: [], context: ContextSnapshot(), models: [missingKey])
        Issue.record("expected an error")
    } catch {
        #expect(error.localizedDescription.contains("no api key"))
    }
}

// MARK: - History

@Test func historyIsReplayedAsAlternatingText() {
    var check = ChatMessage(role: .user, text: "Check the question in the active window.", images: [smallImage()])
    check.isWindowCheck = true
    let history = [
        ChatMessage(role: .user, text: "What is osmosis?", images: [smallImage()]),
        ChatMessage(role: .user, text: "Hello?", images: []),
        ChatMessage(role: .assistant, text: "Diffusion of water.", images: []),
        check,
        ChatMessage(role: .assistant, text: "Because.", images: [], answer: AnswerTag(kind: .single, values: ["B"])),
        ChatMessage(role: .user, text: "Which files?", images: [], promptText: "[Context check] list them")
    ]
    let turns = ModelRouter.normalized(ModelRouter.turns(history: history))
    #expect(turns.map(\.role) == [.user, .assistant, .user, .assistant, .user])
    #expect(turns[0].text == "What is osmosis?\n[1 image attached earlier, not repeated here]\n\nHello?")
    #expect(turns[0].images.isEmpty)
    #expect(turns[2].text.hasPrefix("[Active-window check"))
    #expect(turns[3].text == "Answer B\nBecause.")
    #expect(turns[4].text == "[Context check] list them")
}

@Test func contextLimitDropsOldestTurnsThenGivesUp() throws {
    var model = entry(.openAI)
    model.contextTokens = 1_000
    model.maxOutputTokens = 100
    var request = LLMRequest(system: String(repeating: "x", count: 600), turns: [
        LLMTurn(role: .user, text: String(repeating: "a", count: 800)),
        LLMTurn(role: .assistant, text: String(repeating: "b", count: 800)),
        LLMTurn(role: .user, text: "now")
    ])
    try ModelRouter.fit(&request, entry: model)
    #expect(request.turns.map(\.text) == ["now"])

    var huge = LLMRequest(system: String(repeating: "x", count: 4_000), turns: [LLMTurn(role: .user, text: "now")])
    #expect { try ModelRouter.fit(&huge, entry: model) } throws: { ($0 as? ProviderError)?.kind == .contextTooLong }
}

@Test func claudeCodeCatchesUpOnTurnsItMissed() async throws {
    let api = AnsweredBy(label: "GPT-5 · OpenAI", provider: .openAI, fellBack: true)
    let history = [
        ChatMessage(role: .user, text: "First", images: []),
        ChatMessage(role: .assistant, text: "From Claude", images: []),
        ChatMessage(role: .user, text: "Second", images: []),
        ChatMessage(role: .assistant, text: "From GPT", images: [], answeredBy: api)
    ]
    let catchUp = try #require(ModelRouter.cliCatchUp(history: history))
    #expect(catchUp.contains("Teacher: Second"))
    #expect(catchUp.contains("Assistant (GPT-5 · OpenAI): From GPT"))
    #expect(!catchUp.contains("First"))
    #expect(ModelRouter.cliCatchUp(history: Array(history.prefix(2))) == nil)

    let cli = StubCLI(.success("ok"))
    let router = ModelRouter(cli: cli, transport: ScriptedTransport([]))
    _ = try await router.chat(history: history, text: "Third", images: [], context: ContextSnapshot(),
                              models: [routable(entry(.claudeCLI, model: "opus[1m]"), key: nil)])
    #expect(cli.prompts.first?.hasSuffix("[End of those turns]\n\nThird") == true)
}

@Test func systemPromptKeepsDocumentsFirstAndDescribesTools() {
    var context = ContextSnapshot()
    context.documentsBlock = "<documents>\n</documents>\n"
    var model = entry(.anthropic, tools: true)
    model.webSearch = true
    let noFolders = ModelRouter.systemPrompt(context: context, entry: model)
    #expect(noFolders.hasPrefix("<documents>\n</documents>\n\n" + PromptSettings.instructions))
    #expect(noFolders.contains("No Read tool is available"))
    #expect(noFolders.contains("Web search is available"))
    context.roots = [FileManager.default.temporaryDirectory]
    #expect(ModelRouter.systemPrompt(context: context, entry: model).contains("The Read tool takes file_path"))
}

// MARK: - Clients

@Test func anthropicRequestCachesSystemAndRunsTools() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("refs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let notes = folder.appendingPathComponent("notes.txt")
    try "Mitochondria are the powerhouse.".write(to: notes, atomically: true, encoding: .utf8)

    let transport = ScriptedTransport([
        (200, ["content": [["type": "text", "text": "Let me look."],
                           ["type": "tool_use", "id": "tu_1", "name": "Read", "input": ["file_path": notes.path]]],
               "stop_reason": "tool_use"]),
        (200, anthropicReply("Powerhouse."))
    ])
    var model = entry(.anthropic, model: "claude-opus-5", tools: true)
    model.webSearch = true
    let client = AnthropicClient(connection: APIConnection(entry: model, key: "sk-ant", transport: transport))
    let image = try ClaudeImage(image: smallImage())
    let reply = try await client.complete(LLMRequest(
        system: "SYSTEM", turns: [LLMTurn(role: .user, text: "Q", images: [image])],
        reader: ReferenceReader(directories: [folder.path]), webSearch: true))
    #expect(reply.text == "Powerhouse.")

    let request = try #require(transport.requests.first)
    #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
    #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant")
    #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    let first = transport.bodies[0]
    let system = try #require(first["system"] as? [[String: Any]])
    #expect((system[0]["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
    let tools = try #require(first["tools"] as? [[String: Any]])
    #expect(tools.compactMap { $0["name"] as? String } == ["Read", "web_search"])
    let content = try #require((first["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
    #expect(content.map { $0["type"] as? String } == ["image", "text"])

    let second = try #require(transport.bodies[1]["messages"] as? [[String: Any]])
    #expect(second.map { $0["role"] as? String } == ["user", "assistant", "user"])
    let result = try #require((second[2]["content"] as? [[String: Any]])?.first)
    #expect(result["type"] as? String == "tool_result")
    #expect(result["tool_use_id"] as? String == "tu_1")
    let blocks = try #require(result["content"] as? [[String: Any]])
    #expect(blocks.first?["text"] as? String == "Mitochondria are the powerhouse.")
}

@Test func openAICompatibleBodiesMatchTheProvider() async throws {
    let transport = ScriptedTransport([(200, openAIReply("one")), (200, openAIReply("two")), (200, openAIReply("three"))])
    let request = LLMRequest(system: "S", turns: [LLMTurn(role: .user, text: "Hi")], maxOutputTokens: 300)

    _ = try await OpenAIClient(connection: APIConnection(entry: entry(.openAI), key: "sk", transport: transport)).complete(request)
    _ = try await OpenAIClient(connection: APIConnection(entry: entry(.groq), key: "gsk", transport: transport)).complete(request)
    var azure = entry(.azureOpenAI, model: "my-deployment")
    azure.baseURL = "https://res.openai.azure.com/openai/v1/"
    _ = try await OpenAIClient(connection: APIConnection(entry: azure, key: "az", transport: transport)).complete(request)

    let requests = transport.requests
    #expect(requests[0].url?.absoluteString == "https://api.openai.com/v1/chat/completions")
    #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer sk")
    #expect(transport.bodies[0]["max_completion_tokens"] as? Int == 300)
    #expect(transport.bodies[0]["tools"] == nil)
    // Text-only turns stay plain strings for text-only servers.
    #expect((transport.bodies[0]["messages"] as? [[String: Any]])?.last?["content"] as? String == "Hi")
    #expect(requests[1].url?.absoluteString == "https://api.groq.com/openai/v1/chat/completions")
    #expect(transport.bodies[1]["max_tokens"] as? Int == 300)
    #expect(requests[2].url?.absoluteString == "https://res.openai.azure.com/openai/v1/chat/completions")
    #expect(requests[2].value(forHTTPHeaderField: "api-key") == "az")
    #expect(requests[2].value(forHTTPHeaderField: "Authorization") == nil)
}

@Test func openAIToolCallsReturnImagesInAUserMessage() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("refs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let picture = folder.appendingPathComponent("diagram.png")
    try NSBitmapImageRep(data: smallImage().tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: picture)

    let call: [String: Any] = ["id": "call_1", "type": "function",
                               "function": ["name": "Read", "arguments": "{\"file_path\":\"\(picture.path)\"}"]]
    let transport = ScriptedTransport([
        (200, ["choices": [["message": ["role": "assistant", "content": NSNull(), "tool_calls": [call]]]]]),
        (200, openAIReply("It shows a square."))
    ])
    let client = OpenAIClient(connection: APIConnection(entry: entry(.openRouter, tools: true), key: "or", transport: transport))
    let reply = try await client.complete(LLMRequest(system: "S", turns: [LLMTurn(role: .user, text: "Q")],
                                                     reader: ReferenceReader(directories: [folder.path])))
    #expect(reply.text == "It shows a square.")
    #expect(transport.requests[0].value(forHTTPHeaderField: "X-Title") == "Shortcut")
    let messages = try #require(transport.bodies[1]["messages"] as? [[String: Any]])
    #expect(messages.map { $0["role"] as? String } == ["system", "user", "assistant", "tool", "user"])
    #expect(messages[3]["tool_call_id"] as? String == "call_1")
    let parts = try #require(messages[4]["content"] as? [[String: Any]])
    #expect(parts.first?["type"] as? String == "image_url")
}

@Test func toolRejectionRetriesWithoutTools() async throws {
    let transport = ScriptedTransport([
        (400, ["error": ["message": "registry.ollama.ai/library/llava does not support tools"]]),
        (200, ["message": ["role": "assistant", "content": "Plain answer"], "prompt_eval_count": 9, "eval_count": 3])
    ])
    var model = entry(.ollama, model: "llava", tools: true)
    model.contextTokens = 16_000
    let client = OllamaClient(connection: APIConnection(entry: model, key: nil, transport: transport))
    let image = try ClaudeImage(image: smallImage())
    let reply = try await client.complete(LLMRequest(system: "S", turns: [LLMTurn(role: .user, text: "Q", images: [image])],
                                                     reader: ReferenceReader(directories: ["/tmp"]), maxOutputTokens: 500))
    #expect(reply.text == "Plain answer")
    #expect(transport.requests[0].url?.absoluteString == "http://localhost:11434/api/chat")
    #expect(transport.bodies[0]["tools"] != nil)
    #expect(transport.bodies[1]["tools"] == nil)
    let options = try #require(transport.bodies[1]["options"] as? [String: Any])
    #expect(options["num_ctx"] as? Int == 8_192)
    #expect(options["num_predict"] as? Int == 500)
    let user = try #require((transport.bodies[1]["messages"] as? [[String: Any]])?.last)
    #expect((user["images"] as? [String])?.count == 1)
    #expect(transport.bodies[1]["stream"] as? Bool == false)
}

@Test func geminiUsesNativeShapesAndFunctionCalls() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("refs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let notes = folder.appendingPathComponent("a.md")
    try "# Notes".write(to: notes, atomically: true, encoding: .utf8)

    let callPart: [String: Any] = ["functionCall": ["name": "Read", "args": ["file_path": notes.path]], "thoughtSignature": "sig"]
    let transport = ScriptedTransport([
        (200, ["candidates": [["content": ["role": "model", "parts": [callPart]], "finishReason": "STOP"]]]),
        (200, ["candidates": [["content": ["role": "model", "parts": [["text": "thinking", "thought": true], ["text": "Done."]]],
                               "finishReason": "STOP"]],
               "usageMetadata": ["promptTokenCount": 20, "candidatesTokenCount": 2]])
    ])
    var model = entry(.gemini, model: "models/gemini-2.5-pro", tools: true)
    model.webSearch = true
    let client = GeminiClient(connection: APIConnection(entry: model, key: "g-key", transport: transport))
    let image = try ClaudeImage(image: smallImage())
    let reply = try await client.complete(LLMRequest(system: "S", turns: [
        LLMTurn(role: .user, text: "Earlier"), LLMTurn(role: .assistant, text: "Reply"), LLMTurn(role: .user, text: "Q", images: [image])
    ], reader: ReferenceReader(directories: [folder.path]), webSearch: true))
    #expect(reply.text == "Done.")

    let request = transport.requests[0]
    #expect(request.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:generateContent")
    #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "g-key")
    let first = transport.bodies[0]
    #expect(((first["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]])?.first?["text"] as? String == "S")
    let contents = try #require(first["contents"] as? [[String: Any]])
    #expect(contents.map { $0["role"] as? String } == ["user", "model", "user"])
    #expect(((contents[2]["parts"] as? [[String: Any]])?.first?["inline_data"] as? [String: Any])?["mime_type"] as? String == "image/png")
    #expect((first["tools"] as? [[String: Any]])?.count == 2)

    let followUp = try #require(transport.bodies[1]["contents"] as? [[String: Any]])
    #expect((followUp[3]["parts"] as? [[String: Any]])?.first?["thoughtSignature"] as? String == "sig")
    let response = try #require((followUp[4]["parts"] as? [[String: Any]])?.first?["functionResponse"] as? [String: Any])
    #expect((response["response"] as? [String: Any])?["content"] as? String == "# Notes")
}

@Test func discoveryReadsProviderModelLists() async throws {
    let transport = ScriptedTransport([
        (200, ["data": [["id": "openai/gpt-5", "name": "GPT-5", "context_length": 400_000,
                         "architecture": ["input_modalities": ["text", "image"]], "supported_parameters": ["tools"]],
                        ["id": "deepseek/r1", "architecture": ["input_modalities": ["text"]]]]]),
        (200, ["models": [["name": "models/gemini-2.5-pro", "displayName": "Gemini 2.5 Pro", "inputTokenLimit": 1_048_576,
                           "supportedGenerationMethods": ["generateContent"]],
                          ["name": "models/embedding-001", "supportedGenerationMethods": ["embedContent"]]]]),
        (200, ["models": [["name": "gemma3:12b"]]])
    ])
    let router = try await ModelCatalog.list(for: entry(.openRouter), key: "k", transport: transport)
    #expect(router.map(\.id) == ["openai/gpt-5", "deepseek/r1"])
    #expect(router[0].vision == true && router[0].tools == true && router[0].context == 400_000)
    #expect(router[1].vision == false)
    let gemini = try await ModelCatalog.list(for: entry(.gemini), key: "k", transport: transport)
    #expect(gemini.map(\.id) == ["gemini-2.5-pro"])
    #expect(gemini[0].context == 1_048_576)
    let ollama = try await ModelCatalog.list(for: entry(.ollama), key: nil, transport: transport)
    #expect(ollama.map(\.id) == ["gemma3:12b"])
    #expect(transport.requests[2].url?.absoluteString == "http://localhost:11434/api/tags")
}

// MARK: - Read tool

@Test func readToolStaysInsideTheReferenceFolders() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("reader-\(UUID().uuidString)")
    let folder = base.appendingPathComponent("course")
    let outside = base.appendingPathComponent("private")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    try "inside".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try "secret".write(to: outside.appendingPathComponent("s.txt"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.txt"),
                                               withDestinationURL: outside.appendingPathComponent("s.txt"))

    let reader = ReferenceReader(directories: [folder.path])
    let inside = await reader.run(["file_path": folder.appendingPathComponent("a.txt").path])
    #expect(inside.text == "inside" && !inside.isError)
    for path in [outside.appendingPathComponent("s.txt").path,
                 folder.path + "/../private/s.txt",
                 folder.appendingPathComponent("link.txt").path,
                 base.path + "/course-evil/x.txt"] {
        let denied = await reader.run(["file_path": path])
        #expect(denied.isError, "\(path)")
        #expect(!denied.text.contains("secret"))
    }
    #expect(await reader.run([:]).isError)
    #expect(ReferenceReader.pageRange("2-5") == 2...5)
    #expect(ReferenceReader.pageRange(3) == 3...3)
    #expect(ReferenceReader.pageRange("0") == nil)
}

// MARK: - Live

/// `SHORTCUT_LIVE_OLLAMA=<model> swift test --filter liveOllama` runs a real
/// request against a local Ollama, including the Read tool.
@Test func liveOllamaRoundTrip() async throws {
    guard let name = ProcessInfo.processInfo.environment["SHORTCUT_LIVE_OLLAMA"] else { return }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let secret = folder.appendingPathComponent("codeword.txt")
    try "The course codeword is PELICAN-42.".write(to: secret, atomically: true, encoding: .utf8)

    var context = ContextSnapshot()
    context.roots = [folder]
    context.onDemandFiles = [secret]
    context.documentsBlock = "<documents>\n</documents>\n\n<on_demand_files>\nThese reference files are not embedded above. Open them with Read when a question needs them.\n- \(secret.path) (codeword.txt)\n</on_demand_files>\n"

    var model = ModelEntry(provider: .ollama, model: name)
    model.vision = false
    let details = await ModelCatalog.details(for: model, model: name, key: nil)
    print("live ollama details: \(String(describing: details))")
    let listed = try await ModelCatalog.list(for: model, key: nil)
    #expect(listed.contains { $0.id.hasPrefix(name) })

    let router = ModelRouter(cli: StubCLI(.failure(AppError.claudeNotFound)))
    let reply = try await router.chat(
        history: [], text: "Open the on-demand file with the Read tool and tell me the course codeword. Reply with the codeword only.",
        images: [], context: context,
        models: [RoutableModel(entry: ModelEntry(provider: .claudeCLI), key: nil, problem: nil),
                 RoutableModel(entry: model, key: nil, problem: nil)])
    print("live ollama reply: \(reply.value) — \(reply.answeredBy)")
    #expect(reply.answeredBy.provider == .ollama)
    #expect(reply.answeredBy.fellBack)
    #expect(reply.value.contains("PELICAN"))

    // Text-only models are skipped for images.
    await #expect(throws: AppError.self) {
        _ = try await router.chat(history: [], text: "What is this?", images: [NSImage(size: NSSize(width: 4, height: 4))],
                                  context: context, models: [RoutableModel(entry: model, key: nil, problem: nil)])
    }
}

/// `SHORTCUT_LIVE_CLI=1 swift test --filter liveClaudeCode` sends one small
/// request through the router to the real Claude CLI (billed to the plan).
@Test func liveClaudeCodeRoundTrip() async throws {
    guard ProcessInfo.processInfo.environment["SHORTCUT_LIVE_CLI"] != nil else { return }
    let cli = ClaudeService()
    await cli.resetSession()
    let router = ModelRouter(cli: cli)
    var model = ModelEntry(provider: .claudeCLI)
    model.model = "haiku"
    let reply = try await router.chat(history: [], text: "Reply with exactly the word: ok", images: [],
                                      context: ContextSnapshot(), models: [RoutableModel(entry: model, key: nil, problem: nil)])
    print("live cli reply: \(reply.value) — \(reply.answeredBy)")
    #expect(reply.value.lowercased().contains("ok"))
    #expect(reply.answeredBy.provider == .claudeCLI)
    #expect(!reply.answeredBy.fellBack)
    await cli.resetSession()
}
