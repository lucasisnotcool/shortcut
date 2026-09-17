import AppKit
import SwiftUI

/// Spotlight-style chat card: one input row, then only the latest exchange.
/// The view sizes itself and reports its height so the panel can follow.
struct ChatOverlayView: View {
    @ObservedObject var model: AppModel
    var onHeightChange: (CGFloat) -> Void = { _ in }
    var onClose: () -> Void = {}

    static let width: CGFloat = 560
    static let cornerRadius: CGFloat = 22
    private let maxResponseHeight: CGFloat = 560
    private let maxEditorHeight: CGFloat = 132

    @State private var editorHeight: CGFloat = 20
    @State private var responseHeight: CGFloat = 0

    private var isBusy: Bool { model.isSending || model.isAnsweringWindow }

    private var canSend: Bool {
        !model.isSending &&
        (!model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.pastedImages.isEmpty)
    }

    private var exchange: (question: ChatMessage, reply: ChatMessage?)? {
        guard let index = model.messages.lastIndex(where: { $0.role == .user }) else { return nil }
        let reply = model.messages[(index + 1)...].first { $0.role == .assistant }
        return (model.messages[index], reply)
    }

    var body: some View {
        VStack(spacing: 0) {
            inputRow
            if !model.pastedImages.isEmpty {
                pastedImages
            }
            if exchange != nil || model.transientError != nil {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 1)
                    .padding(.horizontal, 16)
                responseArea
            }
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(WindowDragArea())
        .overlayGlass(cornerRadius: Self.cornerRadius)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: CardHeightKey.self, value: proxy.size.height)
        })
        .onPreferenceChange(CardHeightKey.self) { onHeightChange($0.rounded(.up)) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .tint(.primary)
        .animation(.smooth(duration: 0.18), value: model.messages.count)
        .animation(.smooth(duration: 0.18), value: isBusy)
    }

    // MARK: Input

    private var inputRow: some View {
        HStack(alignment: .top, spacing: 12) {
            ShortcutMark(isBusy: isBusy)
                .frame(width: 20, height: 20)
                .overlay(WindowDragArea().padding(-6).help("Drag to move"))
                .padding(.top, 1)

            ZStack(alignment: .topLeading) {
                if model.draft.isEmpty {
                    Text(model.pastedImages.isEmpty ? "Ask anything" : "Add a question about the image")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
                PasteAwareEditor(
                    text: $model.draft,
                    contentHeight: $editorHeight,
                    onPasteImage: model.addPastedImage,
                    onSubmit: { if canSend { model.sendChat() } },
                    onEscape: onClose
                )
                .frame(height: min(max(editorHeight, 20), maxEditorHeight))
            }
            .padding(.top, 1)

            Button(action: model.sendChat) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(canSend ? Color.primary : Color.secondary.opacity(0.6))
                    .frame(width: 24, height: 24)
                    .overlay(Circle().stroke(canSend ? Color.primary.opacity(0.7) : Color.secondary.opacity(0.3), lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help("Send (Return)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var pastedImages: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.pastedImages) { item in
                    Image(nsImage: item.image)
                        .resizable().scaledToFill()
                        .frame(width: 64, height: 46)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                        .overlay(alignment: .topTrailing) {
                            Button { model.removePastedImage(item) } label: {
                                Image(systemName: "xmark.circle")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.primary)
                                    .background(Circle().fill(.regularMaterial))
                            }
                            .buttonStyle(.plain)
                            .offset(x: 5, y: -5)
                        }
                }
            }
            .padding(.top, 6)
            .padding(.horizontal, 48)
        }
        .padding(.bottom, 12)
    }

    // MARK: Response

    private var responseArea: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                if let exchange {
                    QuestionRow(message: exchange.question)
                    if let reply = exchange.reply {
                        ReplyView(message: reply)
                    } else if isBusy {
                        ThinkingRow(text: exchange.question.isWindowCheck ? "Reading the window…" : "Thinking…")
                    }
                } else if model.isAnsweringWindow {
                    ThinkingRow(text: "Capturing the window…")
                }
                if let error = model.transientError {
                    ErrorRow(text: error, onDismiss: model.clearError)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: ResponseHeightKey.self, value: proxy.size.height)
            })
        }
        // Never show a scroller: with "always show scroll bars", a scroller that
        // appears near the height limit narrows the content, which shrinks it
        // below the limit, which hides the scroller again — an endless layout loop.
        .scrollIndicators(.never)
        .frame(height: min(responseHeight, maxResponseHeight))
        .onPreferenceChange(ResponseHeightKey.self) { height in
            let rounded = height.rounded(.up)
            if abs(rounded - responseHeight) >= 1 { responseHeight = rounded }
        }
    }
}

// MARK: - Pieces

struct QuestionRow: View {
    let message: ChatMessage
    var lineLimit: Int? = 2
    var emphasized = false
    var maxImageHeight: CGFloat? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: message.isWindowCheck ? "macwindow" : "person")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.system(size: emphasized ? 13.5 : 12.5, weight: emphasized ? .medium : .regular))
                        .foregroundStyle(emphasized ? .primary : .secondary)
                        .lineLimit(lineLimit)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            // Full card width, so the captured question can be read and checked.
            ForEach(Array(message.images.enumerated()), id: \.offset) { _, image in
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: maxImageHeight, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
            }
        }
    }
}

struct ReplyView: View {
    let message: ChatMessage
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let answer = message.answer {
                AnswerHeader(answer: answer)
            }
            Text(Self.markdown(message.text))
                .font(.system(size: 13.5))
                .lineSpacing(2.5)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                if let answeredBy = message.answeredBy {
                    Text(answeredBy.fellBack ? "\(answeredBy.label) · fallback" : answeredBy.label)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .help(answeredBy.skipped.isEmpty
                              ? "Answered by \(answeredBy.label)"
                              : "Answered by \(answeredBy.label). Skipped: \(answeredBy.skipped.joined(separator: "; "))")
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 28)
    }

    static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// One outlined circle per selected option, a capsule for sequences and
/// values, or "!" when Claude gave no answer.
struct AnswerHeader: View {
    let answer: AnswerTag

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                ForEach(Array(answer.headerTokens.enumerated()), id: \.offset) { _, token in
                    Text(token)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, token.count > 1 ? 12 : 0)
                        .frame(minWidth: 32, minHeight: 32)
                        .background(RoundedRectangle(cornerRadius: 16, style: .circular).strokeBorder(Color.primary.opacity(0.7), lineWidth: 1.2))
                }
            }
            .padding(1)
            .fixedSize()
            .layoutPriority(1)
            VStack(alignment: .leading, spacing: 1) {
                Text(answer.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                Text(answer.subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

struct ThinkingRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini)
            Text(text).font(.system(size: 12.5)).foregroundStyle(.secondary)
        }
        .padding(.leading, 28)
    }
}

struct ErrorRow: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.primary)
                .frame(width: 20)
            Text(text)
                .font(.system(size: 12.5))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
    }
}

/// The app's circle mark; the ring sweeps while a request is running.
struct ShortcutMark: View {
    let isBusy: Bool
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(isBusy ? 0.15 : 0.55), lineWidth: 1.8)
            if isBusy {
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(Color.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .onAppear {
                        spin = false
                        withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true }
                    }
            } else {
                EmptyView()
            }
        }
    }
}

/// Moves the window when dragged. SwiftUI content in a borderless panel does
/// not reliably honour `isMovableByWindowBackground`, so drag explicitly.
private struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

private struct CardHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct ResponseHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension View {
    /// Liquid Glass on macOS 26+, translucent material before that. The tint
    /// must stay strong: with clear glass, dark-mode (white) text vanished over
    /// a white window, and light-mode text over a dark one.
    @ViewBuilder
    func overlayGlass(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let tint = Color(nsColor: .windowBackgroundColor).opacity(0.72)
        if #available(macOS 26.0, *) {
            self
                .background(tint, in: shape)
                .glassEffect(.regular, in: shape)
        } else {
            self
                .background(tint, in: shape)
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.22), lineWidth: 0.5))
        }
    }
}
