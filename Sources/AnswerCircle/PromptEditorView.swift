import AppKit
import SwiftUI

/// Shows exactly what Shortcut sends to Claude, and lets the teacher edit
/// the two prompts that are not generated.
struct PromptEditorView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private enum Section: String, CaseIterable, Identifiable {
        case instructions = "Session Instructions"
        case windowCheck = "Window Check"
        case assembled = "How It Fits Together"
        var id: Self { self }
    }

    @State private var section: Section = .instructions
    @State private var instructions = PromptSettings.instructions
    @State private var windowCheck = PromptSettings.windowCheck

    private var hasChanges: Bool {
        instructions != PromptSettings.instructions || windowCheck != PromptSettings.windowCheck
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch section {
            case .instructions:
                editor(
                    text: $instructions,
                    defaultText: PromptSettings.defaultInstructions,
                    caption: "The system prompt for every request, placed after the reference documents. Applies from the next request; the conversation does not need a reset. Changing it makes the next request reload the course files into Claude's cache (slower, about $1.70 notional, once)."
                )
            case .windowCheck:
                editor(
                    text: $windowCheck,
                    defaultText: PromptSettings.defaultWindowCheck,
                    caption: "Sent with each screenshot from the both-Option shortcut. This fixed reply format is always added after it, because Shortcut reads the answer from it:",
                    footer: PromptSettings.windowCheckReplyFormat
                )
            case .assembled:
                assembled
            }

            HStack {
                if hasChanges {
                    Text("Unsaved changes").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    PromptSettings.instructions = instructions
                    PromptSettings.windowCheck = windowCheck
                    appLog.notice("Prompts saved (instructions customized: \(PromptSettings.isInstructionsCustomized), window check customized: \(PromptSettings.isWindowCheckCustomized))")
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!hasChanges)
            }
        }
        .padding(20)
        .frame(width: 720, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(.primary)
    }

    private func editor(text: Binding<String>, defaultText: String, caption: String, footer: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: text)
                .font(.system(size: 12.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
            HStack(alignment: .top) {
                Text(caption).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Restore Default") { text.wrappedValue = defaultText }
                    .controlSize(.small)
                    .disabled(text.wrappedValue == defaultText)
            }
            if let footer {
                Text(footer)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            }
        }
    }

    private var assembled: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Each request runs `claude -p --model \(ClaudeService.model)`, resuming the shared session, with:")
                .font(.callout)
            VStack(alignment: .leading, spacing: 10) {
                part("1", "System prompt, part 1 — reference documents (generated)",
                     "Text of \(model.context.files.filter { if case .inline = $0.status { return true } else { return false } }.count) files from your reference folders in <documents> tags, ≈\(model.context.inlineTokens.formatted()) tokens, plus any on-demand files. Rebuilt when files change.")
                part("2", "System prompt, part 2 — Session Instructions (editable)",
                     "Your text from the first tab.")
                part("3", "Message — what you typed, or the Window Check prompt (editable) with the screenshot attached",
                     "Pasted images and screenshots are attached inline. The context check (Verify) sends its own fixed message.")
                part("4", "Tools",
                     "Read, WebSearch and WebFetch only; read access limited to the reference folders. Customizations, hooks and MCP servers are disabled.")
            }
            Text("The exact system prompt of the most recent request is saved on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Open Last System Prompt") { openLastSystemPrompt() }
                Button("Show in Finder") {
                    if let url = try? ClaudeService.systemPromptURL() {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
            Spacer()
        }
    }

    private func part(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .frame(width: 20, height: 20)
                .overlay(Circle().stroke(Color.primary.opacity(0.5)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func openLastSystemPrompt() {
        guard let url = try? ClaudeService.systemPromptURL(),
              FileManager.default.fileExists(atPath: url.path) else { return }
        let editor = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }
}
