import AppKit
import ApplicationServices
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var mainWindow: NSWindow?
    private var overlayController: OverlayPanelController?
    private var statusController: StatusItemController?
    private var shortcutMonitor: GlobalShortcutMonitor?
    private var activationObserver: NSObjectProtocol?
    private var lastExternalApplicationPID: pid_t?
    private var qcObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let overlay = OverlayPanelController(model: model)
        overlayController = overlay
        statusController = StatusItemController(model: model, actions: .init(
            openMain: { [weak self] in self?.showMainWindow() },
            openChat: { [weak self] in self?.showOverlay() },
            checkWindow: { [weak self] in self?.answerCurrentWindow() }
        ))

        shortcutMonitor = GlobalShortcutMonitor(
            onDoubleOption: { [weak self] in self?.showOverlay() },
            onBothOptions: { [weak self] in self?.answerCurrentWindow() }
        )
        shortcutMonitor?.isCapturingKeyboard = { [weak overlay] in overlay?.hasKeyboardFocus ?? false }
        shortcutMonitor?.start()

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            Task { @MainActor in
                self?.lastExternalApplicationPID = app.processIdentifier
            }
        }

        if ProcessInfo.processInfo.environment["SHORTCUT_QC"] == "1" {
            installQCTriggers()
        }

        model.refreshPermissionState()
        showMainWindow()
    }

    /// Opt-in test hooks (launch with `open --env SHORTCUT_QC=1`) so both
    /// gestures can be exercised without physical key presses.
    private func installQCTriggers() {
        let center = DistributedNotificationCenter.default()
        let triggers: [(String, @MainActor (AppDelegate) -> Void)] = [
            ("local.lohzh.Shortcut.qc.chat", { $0.showOverlay() }),
            ("local.lohzh.Shortcut.qc.capture", { $0.answerCurrentWindow() }),
            ("local.lohzh.Shortcut.qc.close", { $0.overlayController?.close() }),
            ("local.lohzh.Shortcut.qc.verify", { $0.model.verifyContext() })
        ]
        for (name, action) in triggers {
            qcObservers.append(center.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    appLog.notice("QC trigger \(name, privacy: .public)")
                    action(self)
                }
            })
        }
        appLog.notice("QC triggers installed")
    }

    func applicationWillTerminate(_ notification: Notification) {
        shortcutMonitor?.stop()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Picks up permission changes made in System Settings.
        model.refreshPermissionState()
        shortcutMonitor?.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
    }

    func showMainWindow() {
        if mainWindow == nil {
            let rootView = MainView(model: model)
            let hostingController = NSHostingController(rootView: rootView)
            // Otherwise the window grows to SwiftUI's ideal height.
            hostingController.sizingOptions = []
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Shortcut"
            window.setContentSize(NSSize(width: 1060, height: 700))
            window.minSize = NSSize(width: 840, height: 560)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.center()
            mainWindow = window
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.refreshPermissionState()
    }

    private func showOverlay() {
        overlayController?.show()
    }

    private func answerCurrentWindow() {
        guard !model.isAnsweringWindow else { return }
        overlayController?.close()

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let targetPID = (frontPID == ownPID ? nil : frontPID)
            ?? Self.topmostWindowOwner(excluding: ownPID)
            ?? lastExternalApplicationPID

        appLog.info("Window check requested for pid \(targetPID ?? -1)")
        guard let targetPID else {
            model.reportWindowAnswerFailure("Could not determine the active application.")
            return
        }

        model.answerActiveWindow(processID: targetPID)
    }

    /// Owner of the frontmost normal window that isn't Shortcut's, used when
    /// Shortcut itself is the active app (e.g. its settings window has focus).
    private static func topmostWindowOwner(excluding ownPID: pid_t) -> pid_t? {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for entry in info {
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  (bounds["Width"] ?? 0) >= 160, (bounds["Height"] ?? 0) >= 120 else { continue }
            return pid
        }
        return nil
    }
}
