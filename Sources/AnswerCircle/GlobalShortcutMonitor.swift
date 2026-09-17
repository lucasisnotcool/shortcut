import AppKit

enum OptionGestureAction: Equatable {
    case none
    case showChat
    case captureWindow
}

struct OptionGestureRecognizer {
    private var optionDown: Set<UInt16> = []
    private var validBarePress: [UInt16: Bool] = [:]
    private var lastRelease: [UInt16: TimeInterval] = [:]
    private var comboConsumed = false

    private let optionKeys: Set<UInt16> = [58, 61]
    private let doublePressInterval: TimeInterval = 0.38

    mutating func handleModifierTransition(
        key: UInt16,
        optionModifierPresent: Bool,
        timestamp: TimeInterval
    ) -> OptionGestureAction {
        guard optionKeys.contains(key) else { return .none }

        if !optionDown.contains(key) {
            // Ignore an orphaned release if monitoring began mid-press.
            guard optionModifierPresent else { return .none }
            optionDown.insert(key)
            validBarePress[key] = true
            if optionDown.count == 2 {
                comboConsumed = true
                lastRelease.removeAll()
                validBarePress[58] = false
                validBarePress[61] = false
                return .captureWindow
            }
            return .none
        }

        optionDown.remove(key)
        if comboConsumed {
            if optionDown.isEmpty { comboConsumed = false }
            return .none
        }
        guard validBarePress[key] == true else { return .none }
        validBarePress[key] = false
        if let previous = lastRelease[key], timestamp - previous <= doublePressInterval {
            lastRelease.removeAll()
            return .showChat
        }
        lastRelease[key] = timestamp
        if let otherKey = optionKeys.first(where: { $0 != key }) {
            lastRelease[otherKey] = nil
        }
        return .none
    }

    mutating func invalidateBarePresses() {
        for key in optionDown { validBarePress[key] = false }
    }

    mutating func reset() {
        optionDown.removeAll()
        validBarePress.removeAll()
        lastRelease.removeAll()
        comboConsumed = false
    }
}

@MainActor
final class GlobalShortcutMonitor {
    private let onDoubleOption: () -> Void
    private let onBothOptions: () -> Void
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var recognizer = OptionGestureRecognizer()

    init(onDoubleOption: @escaping () -> Void, onBothOptions: @escaping () -> Void) {
        self.onDoubleOption = onDoubleOption
        self.onBothOptions = onBothOptions
    }

    func start() {
        guard globalMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        recognizer.reset()
    }

    private func handle(_ event: NSEvent) {
        guard event.type == .flagsChanged else {
            recognizer.invalidateBarePresses()
            return
        }
        let action = recognizer.handleModifierTransition(
            key: event.keyCode,
            optionModifierPresent: event.modifierFlags.contains(.option),
            timestamp: ProcessInfo.processInfo.systemUptime
        )
        switch action {
        case .none:
            break
        case .showChat:
            onDoubleOption()
        case .captureWindow:
            onBothOptions()
        }
    }
}
