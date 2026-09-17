import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation

enum MessageRole: String, Codable {
    case user
    case assistant
}

struct ChatImage: Identifiable {
    let id = UUID()
    let image: NSImage
}

struct ChatMessage: Identifiable {
    var id = UUID()
    let role: MessageRole
    let text: String
    let images: [NSImage]
    /// Set on assistant messages produced by an active-window check.
    var answer: AnswerTag? = nil
    /// Set on user messages that represent an active-window check.
    var isWindowCheck = false
    /// Set on user messages whose text sent to the model differs from what is shown.
    var promptText: String? = nil
    /// Set on assistant messages: the model that replied.
    var answeredBy: AnsweredBy? = nil
}

enum AnswerBadgeState: Equatable {
    case idle
    case loading
    case answer(String)
    case noAnswer
    case error
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var contextRoots: [URL] = []
    @Published private(set) var context = ContextSnapshot()
    @Published private(set) var isIndexing = false
    @Published var messages: [ChatMessage] = [] {
        didSet { conversation.save(messages) }
    }
    @Published var draft = ""
    @Published var pastedImages: [ChatImage] = []
    @Published private(set) var isSending = false
    @Published private(set) var isAnsweringWindow = false
    @Published private(set) var badgeState: AnswerBadgeState = .idle
    @Published private(set) var lastWindowAnswer: WindowAnswer?
    @Published private(set) var transientError: String?
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var screenRecordingGranted = false
    @Published private(set) var claudeExecutableFound = false
    @Published private(set) var claudeAccount: ClaudeAccount?
    @Published private(set) var availableUpdate: AvailableUpdate?

    let models: ModelStore
    /// Opens the Models sheet from anywhere in the main window.
    @Published var isShowingModels = false
    private let router: ModelRouter
    private let capture = ScreenCaptureService()
    private let conversation: ConversationStore
    private let rootsKey = "Shortcut.ContextRoots"
    private let legacyAttachmentsKey = "AnswerCircle.ContextAttachmentPaths"
    private var indexTask: Task<ContextSnapshot, Never>?
    private var modelsObserver: AnyCancellable?

    var isBusy: Bool { isSending || isAnsweringWindow }

    init(conversation: ConversationStore = ConversationStore(),
         models: ModelStore? = nil,
         router: ModelRouter = ModelRouter()) {
        self.conversation = conversation
        self.models = models ?? ModelStore()
        self.router = router
        modelsObserver = self.models.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        messages = conversation.load()
        claudeExecutableFound = ClaudeService.locateExecutable() != nil
        loadRoots()
        refreshContext()
        refreshClaudeAccount()
    }

    var isSetUp: Bool {
        hasReadyModel && accessibilityGranted && screenRecordingGranted
    }

    var claudeReady: Bool { claudeExecutableFound && claudeAccount?.usesSubscription == true }

    /// Whether an enabled model can be tried (the CLI signed in, or an API
    /// model with what it needs).
    func isReady(_ entry: ModelEntry) -> Bool {
        guard entry.isEnabled else { return false }
        if entry.provider == .claudeCLI { return claudeReady }
        return models.setupProblem(entry) == nil
    }

    var readyModels: [ModelEntry] { models.entries.filter(isReady) }

    var hasReadyModel: Bool { !readyModels.isEmpty }

    var usesClaudeCLI: Bool { models.enabledEntries.contains { $0.provider == .claudeCLI } }

    /// What the router needs, looked up here because the Keychain and the
    /// CLI state live on the main actor.
    private func routableModels() -> [RoutableModel] {
        models.entries.map { entry in
            var problem = entry.provider == .claudeCLI ? nil : models.setupProblem(entry)
            if entry.provider == .claudeCLI {
                if !claudeExecutableFound { problem = "Claude Code not installed" }
                else if claudeAccount?.usesSubscription == false { problem = "Claude Code not signed in to a subscription" }
            }
            return RoutableModel(entry: entry, key: entry.provider.acceptsKey ? models.key(for: entry) : nil, problem: problem)
        }
    }

    /// After editing models: failures of the old settings no longer count.
    func modelsChanged() {
        objectWillChange.send()
        Task { await router.clearCooldowns() }
    }

    // MARK: Permissions

    func refreshPermissionState() {
        accessibilityGranted = AXIsProcessTrusted()
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        let found = ClaudeService.locateExecutable() != nil
        if found != claudeExecutableFound || claudeAccount?.usesSubscription == false { refreshClaudeAccount() }
        claudeExecutableFound = found
        appLog.info("Permissions: accessibility=\(self.accessibilityGranted) screenRecording=\(self.screenRecordingGranted) claude=\(self.claudeExecutableFound)")
    }

    func refreshClaudeAccount() {
        Task { claudeAccount = await ClaudeService.account() }
    }

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        schedulePermissionRefresh()
    }

    func requestScreenRecordingPermission() {
        _ = CGRequestScreenCaptureAccess()
        schedulePermissionRefresh()
    }

    // MARK: Updates

    func checkForUpdatesIfDue() {
        guard UpdateChecker.isDue else { return }
        checkForUpdates(userInitiated: false)
    }

    /// A user-initiated check reports the result in an alert.
    func checkForUpdates(userInitiated: Bool) {
        Task {
            let alert = NSAlert()
            do {
                availableUpdate = try await UpdateChecker.latest()
                if let availableUpdate {
                    appLog.notice("Update available: \(availableUpdate.version, privacy: .public)")
                    alert.messageText = "Shortcut \(availableUpdate.version) is available"
                    alert.informativeText = "You have \(AppIdentity.version). Download the new disk image and replace the app in Applications; your settings and permissions carry over."
                    alert.addButton(withTitle: "Download…")
                    alert.addButton(withTitle: "Later")
                } else {
                    alert.messageText = "Shortcut \(AppIdentity.version) is the latest version"
                }
            } catch {
                appLog.error("Update check failed: \(error.localizedDescription, privacy: .public)")
                alert.messageText = "Couldn't check for updates"
                alert.informativeText = error.localizedDescription
            }
            guard userInitiated || availableUpdate != nil && !UpdateChecker.hasAnnounced(availableUpdate!) else { return }
            if let availableUpdate { UpdateChecker.markAnnounced(availableUpdate) }
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn, let availableUpdate {
                NSWorkspace.shared.open(availableUpdate.pageURL)
            }
        }
    }

    // MARK: Context

    func addContextRoots(_ urls: [URL]) {
        let existing = Set(contextRoots.map(\.path))
        let added = urls.map(\.standardizedFileURL).filter { !existing.contains($0.path) }
        guard !added.isEmpty else { return }
        contextRoots = (contextRoots + added).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        saveRoots()
        refreshContext(force: true)
    }

    func removeContextRoot(_ url: URL) {
        contextRoots.removeAll { $0 == url }
        saveRoots()
        refreshContext(force: true)
    }

    /// Rescans the folders. Unless forced, an unchanged fingerprint (same
    /// files, sizes and dates) reuses the current snapshot without rebuilding.
    @discardableResult
    func refreshContext(force: Bool = false) -> Task<ContextSnapshot, Never> {
        if let indexTask, !force { return indexTask }
        let roots = contextRoots
        let previous = context
        isIndexing = true
        let task = Task { [weak self] () -> ContextSnapshot in
            let snapshot = await Task.detached(priority: .userInitiated) { () -> ContextSnapshot in
                if !force, previous.roots == roots,
                   ContextLibrary.fingerprint(roots: roots) == previous.fingerprint {
                    return previous
                }
                let started = Date()
                let built = await ContextLibrary.build(roots: roots)
                appLog.info("Context built: \(built.files.count) files, ~\(built.inlineTokens) tokens inline, \(built.onDemandFiles.count) on demand, \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s")
                return built
            }.value
            guard let self else { return snapshot }
            if self.contextRoots == roots {
                self.context = snapshot
                self.isIndexing = false
                self.indexTask = nil
            }
            return snapshot
        }
        indexTask = task
        return task
    }

    /// The latest context, rebuilt first if any file changed since the last scan.
    private func currentContext() async -> ContextSnapshot {
        if let indexTask { _ = await indexTask.value }
        return await refreshContext().value
    }

    /// Asks Claude, in the shared chat, which documents it can see.
    func verifyContext() {
        send(text: "Which reference files are loaded?", images: [], prompt: ClaudeService.verificationPrompt)
    }

    // MARK: Chat

    func addPastedImage(_ image: NSImage) {
        pastedImages.append(ChatImage(image: image))
    }

    func removePastedImage(_ image: ChatImage) {
        pastedImages.removeAll { $0.id == image.id }
    }

    func clearBadge() {
        guard !isAnsweringWindow else { return }
        badgeState = .idle
        transientError = nil
    }

    func clearError() {
        transientError = nil
        if badgeState == .error { badgeState = .idle }
    }

    func sendChat() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = pastedImages.map(\.image)
        guard !text.isEmpty || !images.isEmpty, !isSending else { return }
        draft = ""
        pastedImages = []
        send(text: text, images: images, prompt: nil)
    }

    private func send(text: String, images: [NSImage], prompt: String?) {
        guard !isSending else { return }
        let history = messages
        let userMessage = ChatMessage(role: .user, text: text, images: images, promptText: prompt)
        messages.append(userMessage)
        isSending = true
        transientError = nil

        Task {
            do {
                let context = await currentContext()
                let reply = try await router.chat(history: history, text: prompt ?? text, images: images,
                                                  context: context, models: routableModels())
                messages.append(ChatMessage(role: .assistant, text: reply.value, images: [], answeredBy: reply.answeredBy))
            } catch {
                appLog.error("Chat failed: \(error.localizedDescription, privacy: .public)")
                transientError = error.localizedDescription
            }
            isSending = false
        }
    }

    func answerActiveWindow(processID: pid_t) {
        guard !isAnsweringWindow else { return }
        isAnsweringWindow = true
        badgeState = .loading
        transientError = nil
        lastWindowAnswer = nil

        Task {
            var screenshotURL: URL?
            do {
                if !CGPreflightScreenCaptureAccess() {
                    _ = CGRequestScreenCaptureAccess()
                    throw AppError.permissionRequired(ScreenCaptureService.permissionHelp)
                }
                let capturedURL = try await capture.captureActiveWindow(processID: processID)
                screenshotURL = capturedURL
                let screenshotImage = NSImage(contentsOf: capturedURL)
                let history = messages
                messages.append(ChatMessage(
                    role: .user,
                    text: "Check the question in the active window.",
                    images: screenshotImage.map { [$0] } ?? [],
                    isWindowCheck: true
                ))
                let context = await currentContext()
                let reply = try await router.answerQuestion(history: history, screenshot: capturedURL,
                                                            context: context, models: routableModels())
                let answer = reply.value
                lastWindowAnswer = answer
                badgeState = answer.isNoAnswer ? .noAnswer : .answer(answer.tag.badgeText)
                messages.append(ChatMessage(
                    role: .assistant,
                    text: answer.chatText,
                    images: [],
                    answer: answer.tag,
                    answeredBy: reply.answeredBy
                ))
                appLog.info("Window answer: \(answer.tag.kind.rawValue, privacy: .public) \(answer.tag.values.joined(separator: " | "), privacy: .public)")
            } catch {
                appLog.error("Window check failed: \(error.localizedDescription, privacy: .public)")
                transientError = error.localizedDescription
                badgeState = .error
            }
            if let screenshotURL {
                try? FileManager.default.removeItem(at: screenshotURL.deletingLastPathComponent())
            }
            isAnsweringWindow = false
            refreshPermissionState()
        }
    }

    func reportWindowAnswerFailure(_ message: String) {
        appLog.error("Window check failed: \(message, privacy: .public)")
        transientError = message
        badgeState = .error
    }

    /// Clears the conversation and starts a new Claude session.
    /// The loaded folders stay and are sent with the next request.
    func resetSession() {
        guard !isBusy else { return }
        Task {
            await router.reset()
            messages.removeAll()
            conversation.clear()
            pastedImages.removeAll()
            draft = ""
            lastWindowAnswer = nil
            transientError = nil
            badgeState = .idle
        }
    }

    /// Labels for single- and multiple-answer questions: 1–8 or A–H.
    nonisolated static func isValidOption(_ raw: String) -> Bool {
        let label = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return AnswerLabels.choiceNumbers.contains(label) || AnswerLabels.choiceLetters.contains(label)
    }

    private func schedulePermissionRefresh() {
        for delay in [0.5, 1.5, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refreshPermissionState()
            }
        }
    }

    private func loadRoots() {
        let defaults = UserDefaults.standard
        let paths = defaults.stringArray(forKey: rootsKey)
            ?? defaults.stringArray(forKey: legacyAttachmentsKey)
            ?? []
        contextRoots = paths
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    private func saveRoots() {
        UserDefaults.standard.set(contextRoots.map(\.path), forKey: rootsKey)
        UserDefaults.standard.removeObject(forKey: legacyAttachmentsKey)
    }
}

/// Keeps the shared conversation on disk so the main window shows it after a relaunch.
final class ConversationStore {
    private struct StoredMessage: Codable {
        let id: UUID
        let role: MessageRole
        let text: String
        let imageFiles: [String]
        let answer: AnswerTag?
        // Written by earlier versions.
        let answerOption: String?
        let answerIsMultiple: Bool?
        let answerIsTrueFalse: Bool?
        let isWindowCheck: Bool
        let promptText: String?
        let answeredBy: AnsweredBy?
    }

    private let directory: URL?
    private var imageNames: [ObjectIdentifier: String] = [:]

    /// `directory: nil` keeps the conversation in memory only (tests).
    init(directory: URL? = ConversationStore.defaultDirectory) {
        self.directory = directory
    }

    static var defaultDirectory: URL? {
        try? AppIdentity.supportDirectory().appendingPathComponent("Conversation", isDirectory: true)
    }

    private var indexURL: URL? { directory?.appendingPathComponent("messages.json") }

    func load() -> [ChatMessage] {
        guard let directory, let indexURL, let data = try? Data(contentsOf: indexURL),
              let stored = try? JSONDecoder().decode([StoredMessage].self, from: data) else { return [] }
        return stored.map { item in
            var images: [NSImage] = []
            for name in item.imageFiles {
                guard let image = NSImage(contentsOf: directory.appendingPathComponent(name)) else { continue }
                imageNames[ObjectIdentifier(image)] = name
                images.append(image)
            }
            return ChatMessage(id: item.id, role: item.role, text: item.text, images: images,
                               answer: item.answer ?? item.answerOption.map {
                                   AnswerTag(legacy: $0, isMultiple: item.answerIsMultiple ?? false,
                                             isTrueFalse: item.answerIsTrueFalse ?? false)
                               },
                               isWindowCheck: item.isWindowCheck,
                               promptText: item.promptText,
                               answeredBy: item.answeredBy)
        }
    }

    func save(_ messages: [ChatMessage]) {
        guard let directory, let indexURL else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stored = try messages.map { message in
                StoredMessage(
                    id: message.id,
                    role: message.role,
                    text: message.text,
                    imageFiles: try message.images.enumerated().map { index, image in
                        try imageFile(for: image, name: "\(message.id.uuidString)-\(index).png", in: directory)
                    },
                    answer: message.answer,
                    answerOption: nil,
                    answerIsMultiple: nil,
                    answerIsTrueFalse: nil,
                    isWindowCheck: message.isWindowCheck,
                    promptText: message.promptText,
                    answeredBy: message.answeredBy
                )
            }
            try JSONEncoder().encode(stored).write(to: indexURL, options: .atomic)
        } catch {
            appLog.error("Could not save conversation: \(error.localizedDescription, privacy: .public)")
        }
    }

    func clear() {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
        imageNames.removeAll()
    }

    private func imageFile(for image: NSImage, name: String, in directory: URL) throws -> String {
        if let existing = imageNames[ObjectIdentifier(image)] { return existing }
        let url = directory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            try Self.downscaledPNG(image, maxWidth: 1600).write(to: url, options: .atomic)
        }
        imageNames[ObjectIdentifier(image)] = name
        return name
    }

    private static func downscaledPNG(_ image: NSImage, maxWidth: CGFloat) throws -> Data {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw AppError.processFailed("image could not be encoded")
        }
        let scale = min(1, maxWidth / CGFloat(source.width))
        let width = max(1, Int(CGFloat(source.width) * scale))
        let height = max(1, Int(CGFloat(source.height) * scale))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw AppError.processFailed("image could not be encoded")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: source, size: .zero).draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw AppError.processFailed("image could not be encoded")
        }
        return png
    }
}

enum AppError: LocalizedError {
    case claudeNotFound
    case processFailed(String)
    case invalidResponse(String)
    case noWindow
    case permissionRequired(String)

    var errorDescription: String? {
        switch self {
        case .claudeNotFound:
            return "Claude CLI was not found. Install it or make it available at ~/.local/bin/claude."
        case .processFailed(let detail), .invalidResponse(let detail), .permissionRequired(let detail):
            return detail
        case .noWindow:
            return "No capturable window was found for the active application."
        }
    }
}
