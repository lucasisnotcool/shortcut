import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    struct Actions {
        let openMain: () -> Void
        let openChat: () -> Void
        let checkWindow: () -> Void
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: AppModel
    private let actions: Actions
    private var cancellables: Set<AnyCancellable> = []
    private var spinnerTimer: Timer?
    private var spinnerAngle: CGFloat = 0

    init(model: AppModel, actions: Actions) {
        self.model = model
        self.actions = actions
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        model.$badgeState.sink { [weak self] state in
            self?.render(state)
        }.store(in: &cancellables)
        model.$transientError.sink { [weak self] _ in
            guard let self else { return }
            self.render(self.model.badgeState)
        }.store(in: &cancellables)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if model.badgeState == .noAnswer, let answer = model.lastWindowAnswer {
            menu.addItem(viewItem(StatusMenuDetail(
                title: "No answer",
                detail: answer.explanation
            )))
            menu.addItem(.separator())
        } else if case .answer = model.badgeState, let answer = model.lastWindowAnswer {
            menu.addItem(viewItem(StatusMenuDetail(
                title: "\(answer.tag.title) · \(answer.tag.subtitle)",
                detail: answer.chatText
            )))
            menu.addItem(.separator())
        } else if model.badgeState == .error, let error = model.transientError {
            menu.addItem(viewItem(StatusMenuDetail(
                title: "Last check failed",
                detail: error
            )))
            menu.addItem(.separator())
        } else if model.badgeState == .loading {
            menu.addItem(disabled("Checking the active window…"))
            menu.addItem(.separator())
        }

        menu.addItem(item("Open Chat", hint: "⌥ ⌥", action: #selector(openChat)))
        menu.addItem(item("Check Active Window", hint: "⌥ + ⌥", action: #selector(checkWindow)))
        if model.badgeState != .idle && model.badgeState != .loading {
            menu.addItem(item("Clear Badge", action: #selector(clearBadge)))
        }
        menu.addItem(.separator())
        menu.addItem(item("Shortcut Settings…", action: #selector(openMain)))
        menu.addItem(item("Quit Shortcut", action: #selector(quitApp)))
    }

    private func item(_ title: String, hint: String? = nil, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let hint {
            // Informational only: the gestures are global, not menu key equivalents.
            item.attributedTitle = NSAttributedString(string: title)
            item.badge = NSMenuItemBadge(string: hint)
        }
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func viewItem(_ view: StatusMenuDetail) -> NSMenuItem {
        let hosting = NSHostingView(rootView: view)
        hosting.frame.size = hosting.fittingSize
        let item = NSMenuItem()
        item.view = hosting
        return item
    }

    @objc private func openMain() { actions.openMain() }
    @objc private func openChat() { actions.openChat() }
    @objc private func checkWindow() { actions.checkWindow() }
    @objc private func clearBadge() { model.clearBadge() }
    @objc private func quitApp() { NSApp.terminate(nil) }

    // MARK: Badge

    private func render(_ state: AnswerBadgeState) {
        spinnerTimer?.invalidate()
        spinnerTimer = nil
        switch state {
        case .idle:
            statusItem.button?.image = Self.badgeImage(text: nil)
            statusItem.button?.toolTip = "Shortcut"
        case .loading:
            statusItem.button?.toolTip = "Checking the active window…"
            drawSpinner()
            spinnerTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.spinnerAngle -= 12
                    self.drawSpinner()
                }
            }
        case .answer(let option):
            statusItem.button?.image = Self.badgeImage(text: option)
            statusItem.button?.toolTip = model.lastWindowAnswer?.tag.title ?? option
        case .noAnswer:
            statusItem.button?.image = Self.badgeImage(text: "!")
            statusItem.button?.toolTip = "No answer: \(model.lastWindowAnswer?.explanation ?? "")"
        case .error:
            statusItem.button?.image = Self.badgeImage(text: "×")
            statusItem.button?.toolTip = model.transientError ?? "Shortcut encountered an error"
        }
    }

    /// Monochrome template images: an outlined ring, optionally with a
    /// character inside; several answers ("1 3 4") get an outlined capsule
    /// that widens to fit. The menu bar tints them for light and dark mode.
    static func badgeImage(text: String?) -> NSImage {
        let font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        let value = text.map { NSAttributedString(string: $0, attributes: [.font: font, .foregroundColor: NSColor.black]) }
        let textWidth = ceil(value?.size().width ?? 0)
        let isCapsule = (text?.count ?? 0) > 1
        let size = NSSize(width: isCapsule ? max(18, textWidth + 12) : 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setStroke()
            let outline = rect.insetBy(dx: 1.25, dy: 1.25)
            let shape = isCapsule
                ? NSBezierPath(roundedRect: outline, xRadius: outline.height / 2, yRadius: outline.height / 2)
                : NSBezierPath(ovalIn: outline)
            shape.lineWidth = 1.4
            shape.stroke()
            if let value {
                let textSize = value.size()
                value.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2))
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private func drawSpinner() {
        let angle = spinnerAngle
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let radius = rect.width / 2 - 1.25
            NSColor.black.withAlphaComponent(0.25).setStroke()
            let track = NSBezierPath(ovalIn: rect.insetBy(dx: 1.25, dy: 1.25))
            track.lineWidth = 1.4
            track.stroke()
            NSColor.black.setStroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY), radius: radius, startAngle: angle, endAngle: angle + 100)
            arc.lineWidth = 1.8
            arc.lineCapStyle = .round
            arc.stroke()
            return true
        }
        image.isTemplate = true
        statusItem.button?.image = image
    }
}

private struct StatusMenuDetail: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(ReplyView.markdown(detail))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(24)
        }
        .frame(width: 300, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}
