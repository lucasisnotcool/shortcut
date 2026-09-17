import AppKit

/// First-run help for a downloaded copy: the welcome notice, moving out of the
/// disk image, and running the Claude CLI's install and sign-in in Terminal.
@MainActor
enum SetupAssistant {
    /// Anthropic's native installer; puts `claude` in ~/.local/bin.
    static let installCommand = "curl -fsSL https://claude.ai/install.sh | bash"
    static let signInCommand = "claude auth login"
    private static let welcomeKey = "Shortcut.AcceptedWelcome"

    // MARK: Welcome

    /// Returns false if the user chose to quit.
    static func showWelcomeIfNeeded() -> Bool {
        guard !UserDefaults.standard.bool(forKey: welcomeKey) else { return true }
        let alert = NSAlert()
        alert.messageText = "Welcome to Shortcut"
        alert.informativeText = """
        Shortcut is for teaching staff: it checks the question you are presenting against your own course materials.

        • It uses your own Claude subscription through the Claude CLI.
        • Your reference folders, screenshots of the active window, pasted images and the chat are sent to Anthropic.
        • Don't use it to answer an assessment you are taking.
        """
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Quit")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        UserDefaults.standard.set(true, forKey: welcomeKey)
        return true
    }

    // MARK: Location

    /// Launched from the mounted DMG, or from a quarantined copy macOS moved
    /// to a random read-only path. Permissions granted there don't stick.
    static var isRunningFromTemporaryLocation: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/")
    }

    /// Offers to copy the app into /Applications and relaunch from there.
    /// Returns true if the app is relaunching.
    static func offerMoveToApplicationsIfNeeded() -> Bool {
        guard isRunningFromTemporaryLocation else { return false }
        let alert = NSAlert()
        alert.messageText = "Move Shortcut to Applications?"
        alert.informativeText = "Shortcut is running from the disk image or a temporary location. Permissions only stick when it runs from the Applications folder."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        let source = Bundle.main.bundleURL
        let destination = URL(fileURLWithPath: "/Applications/Shortcut.app")
        let fileManager = FileManager.default
        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.trashItem(at: destination, resultingItemURL: nil)
            }
            try fileManager.copyItem(at: source, to: destination)
        } catch {
            let failure = NSAlert(error: error)
            failure.informativeText = "Drag Shortcut from the disk image to Applications, then open it from there."
            failure.runModal()
            return false
        }
        appLog.notice("Copied app to /Applications; relaunching")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        return true
    }

    // MARK: Terminal

    static func installClaude() {
        runInTerminal(name: "Install Claude Code", commands: [
            installCommand,
            "echo",
            "echo 'Next, sign in with your claude.ai account:'",
            "\"$HOME/.local/bin/claude\" auth login"
        ])
    }

    static func signInToClaude() {
        guard let executable = ClaudeService.locateExecutable() else { return installClaude() }
        runInTerminal(name: "Sign In to Claude", commands: [
            "\(shellQuoted(executable.path)) auth logout >/dev/null 2>&1",
            "\(shellQuoted(executable.path)) auth login"
        ])
    }

    /// Opens a `.command` script, which Terminal runs in a new window. Needs
    /// no Automation permission, and the user sees exactly what runs.
    private static func runInTerminal(name: String, commands: [String]) {
        let script = (["#!/bin/zsh", "clear", "set -x"] + commands + [
            "set +x",
            "echo",
            "echo 'Done. Switch back to Shortcut; it checks again automatically.'"
        ]).joined(separator: "\n") + "\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            appLog.error("Could not write \(name, privacy: .public) script: \(error.localizedDescription, privacy: .public)")
            return
        }
        NSWorkspace.shared.open(url)
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
