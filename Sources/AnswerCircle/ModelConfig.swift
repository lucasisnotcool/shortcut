import Foundation
import Security

/// The wire protocol a provider speaks. Four clients cover every preset.
enum ProviderAPI: Equatable {
    case claudeCLI
    case anthropic
    case gemini
    case openAI
    case ollama
}

/// A model source the teacher can add. Everything except the Claude CLI and
/// the two native APIs speaks OpenAI Chat Completions.
enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case claudeCLI
    case anthropic
    case openAI
    case gemini
    case openRouter
    case xAI
    case mistral
    case groq
    case deepSeek
    case azureOpenAI
    case ollama
    case lmStudio
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claudeCLI: return "Claude Code (subscription)"
        case .anthropic: return "Anthropic API"
        case .openAI: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .openRouter: return "OpenRouter"
        case .xAI: return "xAI"
        case .mistral: return "Mistral"
        case .groq: return "Groq"
        case .deepSeek: return "DeepSeek"
        case .azureOpenAI: return "Azure OpenAI"
        case .ollama: return "Ollama (local)"
        case .lmStudio: return "LM Studio (local)"
        case .custom: return "Custom (OpenAI-compatible)"
        }
    }

    /// Short name for the chat footer and the model list.
    var shortTitle: String {
        switch self {
        case .claudeCLI: return "Claude Code"
        case .anthropic: return "Anthropic"
        case .gemini: return "Gemini"
        case .azureOpenAI: return "Azure"
        case .ollama: return "Ollama"
        case .lmStudio: return "LM Studio"
        case .custom: return "Custom"
        default: return title
        }
    }

    var api: ProviderAPI {
        switch self {
        case .claudeCLI: return .claudeCLI
        case .anthropic: return .anthropic
        case .gemini: return .gemini
        case .ollama: return .ollama
        default: return .openAI
        }
    }

    /// Empty for providers whose address the teacher must enter.
    var defaultBaseURL: String {
        switch self {
        case .claudeCLI, .azureOpenAI, .custom: return ""
        case .anthropic: return "https://api.anthropic.com"
        case .openAI: return "https://api.openai.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .xAI: return "https://api.x.ai/v1"
        case .mistral: return "https://api.mistral.ai/v1"
        case .groq: return "https://api.groq.com/openai/v1"
        case .deepSeek: return "https://api.deepseek.com/v1"
        case .ollama: return "http://localhost:11434"
        case .lmStudio: return "http://localhost:1234/v1"
        }
    }

    var baseURLPlaceholder: String {
        switch self {
        case .azureOpenAI: return "https://<resource>.openai.azure.com/openai/v1"
        case .custom: return "https://host/v1"
        default: return defaultBaseURL
        }
    }

    var hasBaseURL: Bool { self != .claudeCLI }

    /// Whether requests fail without a key. Custom servers may not need one.
    var requiresKey: Bool {
        switch self {
        case .claudeCLI, .ollama, .lmStudio, .custom: return false
        default: return true
        }
    }

    var acceptsKey: Bool {
        switch self {
        case .claudeCLI, .ollama, .lmStudio: return false
        default: return true
        }
    }

    var isLocal: Bool { self == .ollama || self == .lmStudio }

    /// Provider-side web search Shortcut can switch on.
    var webSearchNote: String? {
        switch self {
        case .claudeCLI: return "WebSearch and WebFetch are always available."
        case .anthropic: return "Anthropic's web search tool ($10 per 1,000 searches)."
        case .gemini: return "Grounding with Google Search."
        case .openRouter: return "OpenRouter's web plugin (billed per request)."
        default: return nil
        }
    }

    var supportsWebSearch: Bool { self == .anthropic || self == .gemini || self == .openRouter }

    var keyPageURL: URL? {
        switch self {
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")
        case .openRouter: return URL(string: "https://openrouter.ai/settings/keys")
        case .xAI: return URL(string: "https://console.x.ai")
        case .mistral: return URL(string: "https://console.mistral.ai/api-keys")
        case .groq: return URL(string: "https://console.groq.com/keys")
        case .deepSeek: return URL(string: "https://platform.deepseek.com/api_keys")
        default: return nil
        }
    }

    /// Filled in when a model is added; the list button fetches the real ones.
    var suggestedModel: String {
        switch self {
        case .claudeCLI: return "opus[1m]"
        case .anthropic: return "claude-opus-5"
        case .openAI: return "gpt-5"
        case .gemini: return "gemini-2.5-pro"
        case .mistral: return "mistral-medium-latest"
        case .deepSeek: return "deepseek-chat"
        case .openRouter, .xAI, .groq, .azureOpenAI, .custom, .ollama, .lmStudio: return ""
        }
    }

    /// DeepSeek's API takes text only; everything else defaults to images on.
    var defaultVision: Bool { self != .deepSeek }
}

/// One entry in the ranked model list. The first available entry answers.
struct ModelEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var provider: ProviderKind
    /// The provider's model id (an alias such as `opus[1m]` for the CLI, a
    /// deployment name for Azure).
    var model: String
    /// Blank shows the model id.
    var name: String = ""
    /// Blank uses the provider's default address.
    var baseURL: String = ""
    var isEnabled = true
    /// Accepts images: needed for window checks and pasted images.
    var vision = true
    /// Offer the sandboxed Read tool for on-demand reference files.
    var tools = true
    var webSearch = false
    /// Tokens; nil means unknown (no pre-flight size check).
    var contextTokens: Int?
    var maxOutputTokens = 8_192
    var temperature: Double?
    /// "Header: value" per line, for gateways that need them.
    var extraHeaders = ""

    init(provider: ProviderKind, model: String? = nil) {
        self.provider = provider
        self.model = model ?? provider.suggestedModel
        vision = provider.defaultVision
        webSearch = provider == .anthropic
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        if model.isEmpty { return "New \(provider.shortTitle) model" }
        return provider == .claudeCLI ? Self.claudeAliasName(model) : model
    }

    /// "opus[1m]" → "Opus · 1M context"; other ids unchanged.
    static func claudeAliasName(_ alias: String) -> String {
        var base = alias
        var suffix = ""
        if base.hasSuffix("[1m]") {
            base.removeLast(4)
            suffix = " · 1M context"
        }
        guard ["opus", "sonnet", "haiku"].contains(base) else { return alias }
        return base.prefix(1).uppercased() + base.dropFirst() + suffix
    }

    /// "Opus · 1M context · Claude Code"
    var label: String { "\(displayName) · \(provider.shortTitle)" }

    var resolvedBaseURL: String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? provider.defaultBaseURL : trimmed
        return value.hasSuffix("/") ? String(value.dropLast()) : value
    }

    /// Providers share one key; custom servers each keep their own.
    var keychainAccount: String {
        provider == .custom ? "custom-\(id.uuidString)" : provider.rawValue
    }

    var headerPairs: [(String, String)] {
        extraHeaders.split(whereSeparator: \.isNewline).compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : (name, value)
        }
    }

    // Tolerates entries saved by older builds with fewer fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        provider = try c.decode(ProviderKind.self, forKey: .provider)
        model = try c.decode(String.self, forKey: .model)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        vision = try c.decodeIfPresent(Bool.self, forKey: .vision) ?? provider.defaultVision
        tools = try c.decodeIfPresent(Bool.self, forKey: .tools) ?? true
        webSearch = try c.decodeIfPresent(Bool.self, forKey: .webSearch) ?? false
        contextTokens = try c.decodeIfPresent(Int.self, forKey: .contextTokens)
        maxOutputTokens = try c.decodeIfPresent(Int.self, forKey: .maxOutputTokens) ?? 8_192
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature)
        extraHeaders = try c.decodeIfPresent(String.self, forKey: .extraHeaders) ?? ""
    }
}

/// The ranked model list, saved in defaults. New models go to the bottom.
@MainActor
final class ModelStore: ObservableObject {
    static let defaultsKey = "Shortcut.Models"

    @Published var entries: [ModelEntry] {
        didSet { if entries != oldValue { save() } }
    }
    /// Bumped when a key is stored or removed, so views re-read the Keychain.
    @Published private(set) var keyRevision = 0

    private let defaults: UserDefaults?
    let keys: KeyStore

    /// `defaults: nil` keeps the list in memory (tests and snapshots).
    init(defaults: UserDefaults? = .standard, keys: KeyStore = KeychainKeyStore()) {
        self.defaults = defaults
        self.keys = keys
        if let data = defaults?.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([ModelEntry].self, from: data), !saved.isEmpty {
            entries = saved
        } else {
            entries = Self.defaultEntries
        }
    }

    /// Before BYOK, Shortcut only ran the CLI with Opus.
    static var defaultEntries: [ModelEntry] { [ModelEntry(provider: .claudeCLI)] }

    var enabledEntries: [ModelEntry] { entries.filter(\.isEnabled) }

    @discardableResult
    func add(_ provider: ProviderKind) -> ModelEntry {
        let entry = ModelEntry(provider: provider)
        entries.append(entry)
        return entry
    }

    func move(from source: IndexSet, to destination: Int) {
        entries.move(fromOffsets: source, toOffset: destination)
    }

    func remove(_ id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        entries.removeAll { $0.id == id }
        // Shared provider keys stay for other entries; a custom server's key goes with it.
        if entry.provider == .custom { keys.delete(account: entry.keychainAccount) }
    }

    func key(for entry: ModelEntry) -> String? { keys.read(account: entry.keychainAccount) }

    func hasKey(for entry: ModelEntry) -> Bool { key(for: entry) != nil }

    func setKey(_ key: String, for entry: ModelEntry) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            keys.delete(account: entry.keychainAccount)
        } else {
            keys.write(trimmed, account: entry.keychainAccount)
        }
        keyRevision += 1
    }

    /// Why an entry cannot be tried right now, or nil when it can.
    func setupProblem(_ entry: ModelEntry) -> String? {
        if entry.model.trimmingCharacters(in: .whitespaces).isEmpty { return "No model id" }
        if entry.provider.hasBaseURL, entry.resolvedBaseURL.isEmpty { return "No server address" }
        if entry.provider.requiresKey, !hasKey(for: entry) { return "No API key" }
        return nil
    }

    private func save() {
        guard let defaults, let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

protocol KeyStore {
    func read(account: String) -> String?
    func write(_ value: String, account: String)
    func delete(account: String)
}

/// API keys live in the login keychain, never in defaults or on disk.
struct KeychainKeyStore: KeyStore {
    var service = AppIdentity.bundleID + ".api-keys"

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func read(account: String) -> String? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    func write(_ value: String, account: String) {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account)
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Shortcut API key (\(account))"
            let added = SecItemAdd(item as CFDictionary, nil)
            if added != errSecSuccess { appLog.error("Keychain add failed for \(account, privacy: .public): \(added)") }
        } else if status != errSecSuccess {
            appLog.error("Keychain update failed for \(account, privacy: .public): \(status)")
        }
    }

    func delete(account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}

/// In-memory keys for tests and snapshots.
final class MemoryKeyStore: KeyStore {
    private var values: [String: String]
    init(_ values: [String: String] = [:]) { self.values = values }
    func read(account: String) -> String? { values[account] }
    func write(_ value: String, account: String) { values[account] = value }
    func delete(account: String) { values[account] = nil }
}
