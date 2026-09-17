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

/// Decides which Option key events other apps (and web pages) get to see.
///
/// A bare Option press is held back. If it turns into one of Shortcut's
/// gestures, it is never delivered. If anything else happens while it is
/// held (a key, a click, a scroll, another modifier), the held presses are
/// replayed first, so Option+key and Option-click keep working everywhere.
struct OptionKeyFilter {
    enum Input: Equatable {
        case option(key: UInt16, isDown: Bool, withOtherModifiers: Bool)
        case otherModifier
        case otherInput
    }

    enum Decision: Equatable {
        case pass
        case swallow
        /// Deliver the held Option presses for these keys, then this event.
        case replayThenPass([UInt16])
    }

    private(set) var held: [UInt16] = []

    mutating func handle(_ input: Input) -> Decision {
        switch input {
        case .option(let key, true, false):
            held.removeAll { $0 == key }
            held.append(key)
            return .swallow
        case .option(let key, false, _) where held.contains(key):
            // The press was never delivered, so its release must not be either.
            held.removeAll { $0 == key }
            return .swallow
        case .option(_, true, true), .otherModifier, .otherInput:
            return flush()
        case .option:
            return .pass
        }
    }

    mutating func reset() { held.removeAll() }

    private mutating func flush() -> Decision {
        guard !held.isEmpty else { return .pass }
        let keys = held
        held.removeAll()
        return .replayThenPass(keys)
    }
}

@MainActor
final class GlobalShortcutMonitor {
    private let onDoubleOption: () -> Void
    private let onBothOptions: () -> Void
    private var recognizer = OptionGestureRecognizer()
    private var filter = OptionKeyFilter()
    /// True while Shortcut's overlay has keyboard focus. The overlay does not
    /// activate Shortcut, so macOS would still send modifier-key changes
    /// (⌘, ⇧, ⌥, ⌃) to the app underneath; they are held back instead.
    var isCapturingKeyboard: () -> Bool = { false }

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    /// Copies of held Option-down events, replayed if the press is not a gesture.
    private var heldEvents: [UInt16: CGEvent] = [:]
    /// Listen-only fallback while the event tap cannot be created (no Accessibility).
    private var globalMonitor: Any?
    private var localMonitor: Any?

    private static let replayMarker: Int64 = 0x5348_4F52_5443_5554  // "SHORTCUT"
    private static let leftOptionMask: UInt64 = 0x20   // NX_DEVICELALTKEYMASK
    private static let rightOptionMask: UInt64 = 0x40  // NX_DEVICERALTKEYMASK

    init(onDoubleOption: @escaping () -> Void, onBothOptions: @escaping () -> Void) {
        self.onDoubleOption = onDoubleOption
        self.onBothOptions = onBothOptions
    }

    var isConsumingKeys: Bool { tap != nil }

    /// Safe to call repeatedly; upgrades from the fallback once the tap can be created.
    func start() {
        if tap == nil, installTap() {
            removeFallbackMonitors()
            appLog.notice("Option gestures: event tap active; gesture keys are not passed to other apps")
        } else if tap == nil, globalMonitor == nil {
            installFallbackMonitors()
            appLog.error("Option gestures: event tap unavailable, using listen-only monitors (keys still reach other apps)")
        }
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
        removeFallbackMonitors()
        recognizer.reset()
        filter.reset()
        heldEvents.removeAll()
    }

    // MARK: Event tap

    private func installTap() -> Bool {
        let types: [CGEventType] = [
            .flagsChanged, .keyDown, .keyUp,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .scrollWheel
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<GlobalShortcutMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return MainActor.assumeIsolated {
                monitor.handleTap(proxy: proxy, type: type, event: event)
            }
        }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        tapSource = source
        return true
    }

    private func handleTap(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Anything held can no longer be matched with its release.
            filter.reset()
            heldEvents.removeAll()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.replayMarker {
            return Unmanaged.passUnretained(event)
        }

        if type == .flagsChanged, isCapturingKeyboard() {
            let key = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if key == 58 || key == 61 {
                let deviceMask = key == 58 ? Self.leftOptionMask : Self.rightOptionMask
                feedRecognizer(key: key, isDown: event.flags.rawValue & deviceMask != 0)
            } else {
                recognizer.invalidateBarePresses()
            }
            // Held presses belong to the overlay now; never replay them underneath.
            filter.reset()
            heldEvents.removeAll()
            return nil
        }

        let input: OptionKeyFilter.Input
        if type == .flagsChanged {
            let key = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            if key == 58 || key == 61 {
                let deviceMask = key == 58 ? Self.leftOptionMask : Self.rightOptionMask
                let isDown = flags.rawValue & deviceMask != 0
                let others = !flags.intersection([.maskCommand, .maskControl, .maskShift]).isEmpty
                input = .option(key: key, isDown: isDown, withOtherModifiers: others)
                feedRecognizer(key: key, isDown: isDown)
                if others { recognizer.invalidateBarePresses() }
            } else {
                input = .otherModifier
                recognizer.invalidateBarePresses()
            }
        } else {
            input = .otherInput
            recognizer.invalidateBarePresses()
        }

        switch filter.handle(input) {
        case .pass:
            return Unmanaged.passUnretained(event)
        case .swallow:
            if case .option(let key, true, _) = input {
                heldEvents[key] = event.copy()
            } else if case .option(let key, false, _) = input {
                heldEvents[key] = nil
            }
            return nil
        case .replayThenPass(let keys):
            for key in keys {
                guard let held = heldEvents.removeValue(forKey: key) else { continue }
                held.setIntegerValueField(.eventSourceUserData, value: Self.replayMarker)
                held.tapPostEvent(proxy)
            }
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: Fallback

    private func installFallbackMonitors() {
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor in self?.handleMonitored(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleMonitored(event)
            return event
        }
    }

    private func removeFallbackMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func handleMonitored(_ event: NSEvent) {
        guard event.type == .flagsChanged else {
            recognizer.invalidateBarePresses()
            return
        }
        feedRecognizer(key: event.keyCode, isDown: event.modifierFlags.contains(.option))
    }

    private func feedRecognizer(key: UInt16, isDown: Bool) {
        let action = recognizer.handleModifierTransition(
            key: key,
            optionModifierPresent: isDown,
            timestamp: ProcessInfo.processInfo.systemUptime
        )
        switch action {
        case .none:
            break
        case .showChat:
            DispatchQueue.main.async { self.onDoubleOption() }
        case .captureWindow:
            DispatchQueue.main.async { self.onBothOptions() }
        }
    }
}
