import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Main window: reference context on the left, the one shared chat on the right.
struct MainView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            ContextSidebar(model: model)
                .frame(width: 350)
            Divider()
            ChatPane(model: model)
                .frame(minWidth: 460)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(.primary)
    }
}

// MARK: - Context sidebar

private struct ContextSidebar: View {
    @ObservedObject var model: AppModel
    @State private var isDropTarget = false

    private var context: ContextSnapshot { model.context }
    private var readyCount: Int { context.files.filter { $0.status.isAvailable }.count }
    private var budgetFraction: Double {
        min(1, Double(context.inlineTokens) / Double(ContextLibrary.inlineTokenBudget))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            permissionStrip
            Divider()
            HStack {
                Text("Reference folders").font(.headline)
                Spacer()
                Button { model.refreshContext(force: true) } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.isIndexing || model.contextRoots.isEmpty)
                .help("Rescan the folders")
                Button("Add…", action: chooseFolders)
                    .controlSize(.small)
            }
            roots
            if !model.contextRoots.isEmpty {
                summary
                fileList
            }
            Spacer(minLength: 0)
            shortcutGuide
        }
        .padding(.horizontal, 18)
        .padding(.top, 34)
        .padding(.bottom, 16)
        .background(isDropTarget ? Color.primary.opacity(0.06) : Color.clear)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTarget, perform: handleDrop)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ShortcutMark(isBusy: model.isBusy)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text("Shortcut").font(.title3.weight(.semibold))
                Text("Claude · \(ClaudeService.modelDisplayName)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var permissionStrip: some View {
        HStack(spacing: 6) {
            StatusPill(title: "Claude CLI", ready: model.claudeExecutableFound, action: nil)
            StatusPill(title: "Accessibility", ready: model.accessibilityGranted) {
                model.requestAccessibilityPermission()
            }
            StatusPill(title: "Screen", ready: model.screenRecordingGranted) {
                model.requestScreenRecordingPermission()
            }
        }
    }

    @ViewBuilder
    private var roots: some View {
        if model.contextRoots.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "folder.badge.plus").font(.system(size: 26)).foregroundStyle(.secondary)
                Text("Add a course folder").font(.callout.weight(.medium))
                Text("Every file inside is loaded into Claude's context, including subfolders.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Choose Folder…", action: chooseFolders).buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .background(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(.tertiary))
        } else {
            VStack(spacing: 4) {
                ForEach(model.contextRoots, id: \.self) { root in
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        Text(root.lastPathComponent).lineLimit(1)
                        Spacer()
                        Button { model.removeContextRoot(root) } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                        .help("Remove from context")
                    }
                    .help(root.path)
                }
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if model.isIndexing {
                    ProgressView().controlSize(.mini)
                    Text("Reading files…").font(.callout)
                } else {
                    Image(systemName: readyCount == context.files.count ? "checkmark.circle" : "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                    Text("\(readyCount) of \(context.files.count) files ready").font(.callout.weight(.medium))
                }
                Spacer()
                Button("Verify") { model.verifyContext() }
                    .controlSize(.small)
                    .disabled(model.isBusy || model.isIndexing)
                    .help("Ask Claude which documents it can see")
            }
            ProgressView(value: budgetFraction)
                .tint(.secondary)
            Text("≈\(context.inlineTokens.formatted()) tokens in context (\(Int(budgetFraction * 100))% of \(ContextLibrary.inlineTokenBudget / 1000)k)"
                 + (context.onDemandFiles.isEmpty ? "" : " · \(context.onDemandFiles.count) on demand"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var fileList: some View {
        List(context.files) { file in
            FileRow(file: file)
                .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(minHeight: 120)
        .opacity(model.isIndexing ? 0.5 : 1)
    }

    private var shortcutGuide: some View {
        VStack(alignment: .leading, spacing: 6) {
            ShortcutHint(keys: "⌥ ⌥", title: "Double-tap Option", subtitle: "Quick chat")
            ShortcutHint(keys: "⌥L+⌥R", title: "Both Option keys", subtitle: "Check the active window")
        }
    }

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Add to Context"
        if panel.runModal() == .OK { model.addContextRoots(panel.urls) }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in model.addContextRoots([url]) } }
            }
        }
        return !providers.isEmpty
    }
}

private struct FileRow: View {
    let file: ContextFile

    private var presentation: (icon: String, detail: String) {
        switch file.status {
        case .inline(let tokens): return ("checkmark.circle", "≈\(tokens.formatted())")
        case .onDemand(let reason): return ("doc.viewfinder", reason)
        case .unsupported(let reason): return ("minus.circle", reason)
        case .failed(let reason): return ("xmark.circle", reason)
        }
    }

    var body: some View {
        let info = presentation
        HStack(spacing: 7) {
            Image(systemName: info.icon).foregroundStyle(.secondary).font(.system(size: 11))
            Text(file.name)
                .font(.system(size: 12))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Text(info.detail)
                .font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .help("\(file.displayPath.removingPercentEncoding ?? file.displayPath)\n\(helpText)")
    }

    private var helpText: String {
        switch file.status {
        case .inline(let tokens): return "In context (≈\(tokens) tokens)"
        case .onDemand(let reason): return "Claude opens this when needed: \(reason)"
        case .unsupported(let reason): return "Not available to Claude: \(reason)"
        case .failed(let reason): return "Could not be read: \(reason)"
        }
    }
}

// MARK: - Chat pane

private struct ChatPane: View {
    @ObservedObject var model: AppModel
    @State private var editorHeight: CGFloat = 20
    @State private var confirmingReset = false

    private var canSend: Bool {
        !model.isSending &&
        (!model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.pastedImages.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let error = model.transientError {
                ErrorRow(text: error, onDismiss: model.clearError)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(Color.primary.opacity(0.04))
            }
            transcript
            Divider()
            composer
        }
    }

    /// Shown in the chat so it is clear the folders survive a reset.
    private var contextStatus: String {
        if model.contextRoots.isEmpty { return "no reference folders" }
        if model.isIndexing { return "loading reference files…" }
        let ready = model.context.files.filter { $0.status.isAvailable }.count
        return "\(ready) reference file\(ready == 1 ? "" : "s") loaded"
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Chat").font(.headline)
                Text("One shared session for quick chat and window checks · \(contextStatus)")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Reference folders are part of every request and are kept when the conversation is reset.")
            }
            Spacer()
            Button("Reset Conversation", systemImage: "arrow.counterclockwise") { confirmingReset = true }
                .disabled(model.isBusy || model.messages.isEmpty)
                .confirmationDialog("Clear the conversation?", isPresented: $confirmingReset) {
                    Button("Reset Conversation", role: .destructive) { model.resetSession() }
                } message: {
                    Text("Starts a new Claude session. Your reference folders stay loaded and are included in the next request.")
                }
        }
        .padding(.horizontal, 20)
        .padding(.top, 30)
        .padding(.bottom, 12)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.messages.isEmpty {
                        emptyState
                    }
                    ForEach(model.messages) { message in
                        Group {
                            if message.role == .user {
                                QuestionRow(message: message, lineLimit: nil, emphasized: true, maxImageHeight: 320)
                                    .padding(.top, message.id == model.messages.first?.id ? 0 : 10)
                            } else {
                                ReplyView(message: message)
                            }
                        }
                        .id(message.id)
                    }
                    if model.isBusy, model.messages.last?.role == .user {
                        ThinkingRow(text: model.isAnsweringWindow ? "Reading the window…" : "Thinking…")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(20)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: model.messages.count) { _, _ in
                withAnimation(.smooth(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: model.isBusy) { _, _ in
                withAnimation(.smooth(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 30)).foregroundStyle(.tertiary)
            Text("No messages yet").font(.headline)
            Text("Ask below, double-tap Option anywhere, or press both Option keys to check a question on screen. Everything lands in this conversation.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.pastedImages.isEmpty {
                HStack(spacing: 8) {
                    ForEach(model.pastedImages) { item in
                        Image(nsImage: item.image)
                            .resizable().scaledToFill()
                            .frame(width: 64, height: 46)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(alignment: .topTrailing) {
                                Button { model.removePastedImage(item) } label: {
                                    Image(systemName: "xmark.circle")
                                        .foregroundStyle(.primary)
                                        .background(Circle().fill(.regularMaterial))
                                }
                                .buttonStyle(.plain)
                                .offset(x: 5, y: -5)
                            }
                    }
                }
                .padding(.top, 4)
            }
            HStack(alignment: .bottom, spacing: 10) {
                ZStack(alignment: .topLeading) {
                    if model.draft.isEmpty {
                        Text("Message Claude — Return to send, ⌘V to paste images")
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                            .allowsHitTesting(false)
                    }
                    PasteAwareEditor(
                        text: $model.draft,
                        contentHeight: $editorHeight,
                        font: .systemFont(ofSize: 14),
                        onPasteImage: model.addPastedImage,
                        onSubmit: { if canSend { model.sendChat() } },
                        onEscape: {}
                    )
                    .frame(height: min(max(editorHeight, 18), 140))
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.7))

                Button(action: model.sendChat) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(canSend ? Color.primary : Color.secondary.opacity(0.6))
                        .frame(width: 30, height: 30)
                        .overlay(Circle().stroke(canSend ? Color.primary.opacity(0.7) : Color.secondary.opacity(0.3), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .padding(.bottom, 3)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

// MARK: - Small pieces

private struct StatusPill: View {
    let title: String
    let ready: Bool
    let action: (() -> Void)?

    var body: some View {
        Button { if !ready { action?() } } label: {
            HStack(spacing: 5) {
                Image(systemName: ready ? "checkmark" : "exclamationmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(ready ? .secondary : .primary)
                Text(title).font(.caption2.weight(.medium))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
        }
        .buttonStyle(.plain)
        .help(ready ? "Ready" : (action == nil ? "Not found" : "Click to enable"))
    }
}

private struct ShortcutHint: View {
    let keys: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 8) {
            Text(keys)
                .font(.system(.caption2, design: .rounded).weight(.bold))
                .frame(width: 52)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .controlBackgroundColor)))
            Text(title).font(.caption.weight(.medium))
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }
}
