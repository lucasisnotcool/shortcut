import AppKit
import SwiftUI

/// The ranked model list: drag to reorder, the first available model answers.
struct ModelsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: ModelStore
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?
    @State private var confirmingRemoval = false

    init(model: AppModel, selection: UUID? = nil) {
        self.model = model
        store = model.models
        _selection = State(initialValue: selection)
    }

    private var selectedIndex: Int? {
        store.entries.firstIndex { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 300)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Text("Keys are kept in your login keychain. Requests go straight from this Mac to the provider.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: 900, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(.primary)
        .onAppear { if selection == nil { selection = store.entries.first?.id } }
        .onChange(of: store.entries) { _, _ in model.modelsChanged() }
        .onChange(of: store.keyRevision) { _, _ in model.modelsChanged() }
    }

    // MARK: List

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Models").font(.headline)
                Text("The first available model answers; if it fails, the next one takes over. Drag to reorder.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 8)

            List(selection: $selection) {
                ForEach(Array(store.entries.enumerated()), id: \.element.id) { index, entry in
                    ModelRow(rank: index + 1, entry: entry, status: status(of: entry),
                             isEnabled: enabledBinding(entry.id))
                        .tag(entry.id)
                }
                .onMove { store.move(from: $0, to: $1) }
            }
            .listStyle(.inset)

            HStack(spacing: 6) {
                Menu {
                    ForEach(ProviderKind.allCases) { provider in
                        Button(provider.title) {
                            let entry = store.add(provider)
                            selection = entry.id
                        }
                    }
                } label: {
                    Label("Add Model", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("New models go to the bottom of the list")
                Spacer()
                Button {
                    confirmingRemoval = true
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(selectedIndex == nil || store.entries.count <= 1)
                .help("Remove the selected model")
                .confirmationDialog("Remove this model?", isPresented: $confirmingRemoval) {
                    Button("Remove", role: .destructive) { removeSelected() }
                } message: {
                    Text("Its settings are deleted. A provider's API key stays in the keychain for its other models.")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let index = selectedIndex {
            ModelEditor(app: model, store: store, entry: entryBinding(store.entries[index].id))
                .id(store.entries[index].id)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "cpu").font(.system(size: 28)).foregroundStyle(.tertiary)
                Text("Select a model, or add one with +.").foregroundStyle(.secondary)
            }
        }
    }

    private func status(of entry: ModelEntry) -> String? {
        if !entry.isEnabled { return "Off" }
        if entry.provider == .claudeCLI {
            if !model.claudeExecutableFound { return "Not installed" }
            if model.claudeAccount?.usesSubscription == false { return "Not signed in" }
            return nil
        }
        if let problem = store.setupProblem(entry) { return problem }
        return entry.vision ? nil : "Text only"
    }

    private func entryBinding(_ id: UUID) -> Binding<ModelEntry> {
        Binding(
            get: { store.entries.first { $0.id == id } ?? ModelEntry(provider: .custom) },
            set: { value in
                if let index = store.entries.firstIndex(where: { $0.id == id }) { store.entries[index] = value }
            }
        )
    }

    private func enabledBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { store.entries.first { $0.id == id }?.isEnabled ?? false },
            set: { value in
                if let index = store.entries.firstIndex(where: { $0.id == id }) { store.entries[index].isEnabled = value }
            }
        )
    }

    private func removeSelected() {
        guard let index = selectedIndex else { return }
        let id = store.entries[index].id
        store.remove(id)
        selection = store.entries[min(index, store.entries.count - 1)].id
    }
}

private struct ModelRow: View {
    let rank: Int
    let entry: ModelEntry
    let status: String?
    @Binding var isEnabled: Bool

    var body: some View {
        HStack(spacing: 9) {
            Text("\(rank)")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .frame(width: 20, height: 20)
                .overlay(Circle().stroke(Color.primary.opacity(entry.isEnabled ? 0.55 : 0.2)))
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayName).lineLimit(1)
                    .foregroundStyle(entry.isEnabled ? .primary : .secondary)
                Text([entry.provider.shortTitle, status].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if status != nil, entry.isEnabled {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
                    .help(status ?? "")
            }
            Toggle("", isOn: $isEnabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(entry.isEnabled ? "Switch off to skip this model" : "Switch on to use this model")
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Editor

private struct ModelEditor: View {
    @ObservedObject var app: AppModel
    @ObservedObject var store: ModelStore
    @Binding var entry: ModelEntry

    @State private var keyDraft = ""
    @State private var discovered: [DiscoveredModel] = []
    @State private var isListing = false
    @State private var listError: String?
    @State private var isTesting = false
    @State private var testResult: (ok: Bool, text: String)?

    private var provider: ProviderKind { entry.provider }
    private var hasKey: Bool {
        _ = store.keyRevision
        return store.hasKey(for: entry)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Provider", value: provider.title)
                TextField("Name", text: $entry.name, prompt: Text(entry.model.isEmpty ? "Shown in the chat" : entry.model))
                modelField
            } footer: {
                if let listError {
                    Text(listError).font(.caption).foregroundStyle(.secondary)
                }
            }

            if provider == .claudeCLI {
                claudeSection
            } else {
                connectionSection
            }

            capabilitiesSection

            if provider != .claudeCLI {
                limitsSection
            }

            testSection
        }
        .formStyle(.grouped)
        .onAppear { if provider == .claudeCLI { discovered = ModelCatalog.claudeAliases.map { DiscoveredModel(id: $0) } } }
    }

    // MARK: Model id

    private var modelField: some View {
        HStack(spacing: 6) {
            TextField(provider == .azureOpenAI ? "Deployment" : "Model", text: $entry.model,
                      prompt: Text(provider == .azureOpenAI ? "deployment name" : "model id"))
                .textFieldStyle(.roundedBorder)
            Menu {
                if discovered.isEmpty {
                    Text(isListing ? "Loading…" : "No list yet")
                } else {
                    ForEach(discovered) { item in
                        Button(item.name.map { "\($0) (\(item.id))" } ?? item.id) { pick(item) }
                    }
                }
            } label: {
                Image(systemName: "list.bullet")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Pick from the fetched list")
            .fixedSize()
            .disabled(discovered.isEmpty)
            if provider != .claudeCLI && provider != .azureOpenAI {
                Button {
                    listModels()
                } label: {
                    if isListing { ProgressView().controlSize(.mini) } else { Text("Fetch List") }
                }
                .controlSize(.small)
                .disabled(isListing || (provider.requiresKey && !hasKey))
                .help("Ask the provider which models are available")
            }
        }
    }

    private func pick(_ item: DiscoveredModel) {
        entry.model = item.id
        if let context = item.context { entry.contextTokens = context }
        if let vision = item.vision { entry.vision = vision }
        if let tools = item.tools { entry.tools = tools }
        if provider == .ollama {
            let snapshot = entry
            Task {
                if let details = await ModelCatalog.details(for: snapshot, model: item.id, key: nil),
                   entry.model == item.id {
                    if let context = details.context { entry.contextTokens = context }
                    if let vision = details.vision { entry.vision = vision }
                    if let tools = details.tools { entry.tools = tools }
                }
            }
        }
    }

    private func listModels() {
        isListing = true
        listError = nil
        let snapshot = entry
        let key = store.key(for: entry)
        Task {
            do {
                let items = try await ModelCatalog.list(for: snapshot, key: key)
                discovered = items.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
                listError = items.isEmpty ? "The provider returned no models." : "\(items.count) models — pick one from the menu."
            } catch {
                listError = "Couldn't list models: \(error.localizedDescription)"
            }
            isListing = false
        }
    }

    // MARK: Sections

    private var claudeSection: some View {
        Section("Claude Code") {
            LabeledContent("Account") {
                Text(app.claudeExecutableFound
                     ? (app.claudeAccount?.summary ?? "Checking…")
                     : "Claude Code is not installed")
                    .foregroundStyle(.secondary)
            }
            HStack {
                if !app.claudeExecutableFound {
                    Button("Install Claude Code…", action: SetupAssistant.installClaude)
                } else if app.claudeAccount?.usesSubscription != true {
                    Button("Sign In…", action: SetupAssistant.signInToClaude)
                }
                Button("Check Again") {
                    app.refreshPermissionState()
                    app.refreshClaudeAccount()
                }
            }
            Text("Runs the Claude CLI on this Mac and bills your claude.ai Pro or Max plan (usage credits cover overflow). Aliases such as opus[1m] follow the newest model.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var connectionSection: some View {
        Section {
            TextField("Server", text: $entry.baseURL, prompt: Text(provider.baseURLPlaceholder))
            if provider.acceptsKey {
                LabeledContent("API key") {
                    HStack(spacing: 6) {
                        SecureField("", text: $keyDraft, prompt: Text(hasKey ? "Saved in keychain" : "Paste key"))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(saveKey)
                        Button("Save", action: saveKey)
                            .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        if hasKey {
                            Button("Remove") { store.setKey("", for: entry) }
                        }
                    }
                }
            }
        } header: {
            Text("Connection")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(connectionNote).font(.caption).foregroundStyle(.secondary)
                if let url = provider.keyPageURL {
                    Link("Get an API key from \(provider.shortTitle)", destination: url).font(.caption)
                }
            }
        }
    }

    private var connectionNote: String {
        switch provider {
        case .ollama: return "Ollama must be running (ollama serve). Pull a vision model such as gemma3 or qwen2.5vl for window checks. The context size is set per request so documents aren't cut off."
        case .lmStudio: return "Start LM Studio's local server. Set the context length when loading the model; LM Studio doesn't report it here."
        case .azureOpenAI: return "Use your resource's v1 endpoint; the model field is the deployment name."
        case .custom: return "Any server with an OpenAI-compatible /chat/completions endpoint. The key is optional and kept for this model only."
        case .openRouter: return "One key reaches many providers. Pick a model with image input for window checks."
        default: return "The key is shared by every \(provider.shortTitle) model in the list."
        }
    }

    private func saveKey() {
        let value = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        store.setKey(value, for: entry)
        keyDraft = ""
        testResult = nil
    }

    private var capabilitiesSection: some View {
        Section {
            if provider == .claudeCLI {
                LabeledContent("Tools", value: "Read, WebSearch, WebFetch")
                LabeledContent("Images", value: "Yes")
            } else {
                Toggle("Accepts images", isOn: $entry.vision)
                    .help("Needed for window checks and pasted images; text-only models are skipped for those")
                Toggle("Read tool for on-demand files", isOn: $entry.tools)
                    .help("Lets the model open reference files that aren't embedded (scans, images, overflow). Switch off for models without tool calling.")
                if provider.supportsWebSearch {
                    Toggle("Web search", isOn: $entry.webSearch)
                }
            }
        } header: {
            Text("Capabilities")
        } footer: {
            if let note = provider.webSearchNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var limitsSection: some View {
        Section {
            TextField("Context window", text: optionalInt($entry.contextTokens), prompt: Text("unknown"))
                .help("In tokens. When set, older turns are dropped to fit, and the model is skipped if the documents alone don't fit.")
            TextField("Max reply tokens", text: requiredInt($entry.maxOutputTokens, fallback: 8_192))
            TextField("Temperature", text: optionalDouble($entry.temperature), prompt: Text("provider default"))
            if provider.api == .openAI || provider.api == .anthropic {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Extra headers")
                    TextEditor(text: $entry.extraHeaders)
                        .font(.system(size: 11.5, design: .monospaced))
                        .frame(height: 44)
                        .scrollContentBackground(.hidden)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    Text("One \"Name: value\" per line, for gateways that need them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Limits")
        } footer: {
            Text(contextNote).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var contextNote: String {
        let needed = app.context.inlineTokens
        guard needed > 0 else { return "Reference documents are sent in full with every request." }
        if let limit = entry.contextTokens, limit < needed + entry.maxOutputTokens {
            return "Your reference documents need about \(needed.formatted()) tokens, more than this model holds: it will be skipped."
        }
        return "Your reference documents need about \(needed.formatted()) tokens per request."
    }

    private var testSection: some View {
        Section {
            HStack {
                Button(provider == .claudeCLI ? "Check Account" : "Test Connection", action: test)
                    .disabled(isTesting || entry.model.isEmpty)
                if isTesting { ProgressView().controlSize(.small) }
                Spacer()
            }
            if let testResult {
                Label(testResult.text, systemImage: testResult.ok ? "checkmark.circle" : "xmark.circle")
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            if provider != .claudeCLI {
                Text(entry.vision
                     ? "Sends a one-word request with a small image, so a model without image input fails here rather than during class."
                     : "Sends a one-word request.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func test() {
        testResult = nil
        if provider == .claudeCLI {
            isTesting = true
            Task {
                let account = await ClaudeService.account()
                if ClaudeService.locateExecutable() == nil {
                    testResult = (false, "Claude Code is not installed.")
                } else if let account {
                    testResult = (account.usesSubscription, account.summary)
                } else {
                    testResult = (false, "Couldn't read the Claude Code sign-in status.")
                }
                app.refreshClaudeAccount()
                isTesting = false
            }
            return
        }
        if let problem = store.setupProblem(entry) {
            testResult = (false, problem)
            return
        }
        isTesting = true
        let snapshot = entry
        let key = store.key(for: entry)
        Task {
            let started = Date()
            do {
                let reply = try await ModelCatalog.test(snapshot, key: key)
                let seconds = Date().timeIntervalSince(started).formatted(.number.precision(.fractionLength(1)))
                let short = reply.count > 60 ? String(reply.prefix(60)) + "…" : reply
                let ok = reply.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .!\n")) == "ok"
                testResult = (true, ok
                    ? "Replied “\(short)” in \(seconds) s\(snapshot.vision ? ", image accepted" : "")."
                    : "Connected in \(seconds) s, but the reply was “\(short)” instead of “ok”. The model works; check it follows instructions.")
                app.modelsChanged()
            } catch {
                testResult = (false, error.localizedDescription)
            }
            isTesting = false
        }
    }

    // MARK: Number fields

    private func optionalInt(_ binding: Binding<Int?>) -> Binding<String> {
        Binding(
            get: { binding.wrappedValue.map(String.init) ?? "" },
            set: { binding.wrappedValue = Int($0.filter(\.isNumber)) }
        )
    }

    private func requiredInt(_ binding: Binding<Int>, fallback: Int) -> Binding<String> {
        Binding(
            get: { String(binding.wrappedValue) },
            set: { binding.wrappedValue = Int($0.filter(\.isNumber)).map { max(1, $0) } ?? fallback }
        )
    }

    private func optionalDouble(_ binding: Binding<Double?>) -> Binding<String> {
        Binding(
            get: { binding.wrappedValue.map { String($0) } ?? "" },
            set: { binding.wrappedValue = Double($0.trimmingCharacters(in: .whitespaces)) }
        )
    }
}
