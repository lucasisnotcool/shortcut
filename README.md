# Shortcut

A private, native macOS menu-bar assistant backed by the locally installed Claude CLI.

## Interactions

- Add a course folder in the main window (sidebar). Every file inside, including subfolders, is loaded straight into Claude's context, and the sidebar shows each file's status: **in context** (with a token estimate), **on demand** (images, scanned PDFs, or anything over the 200k-token budget; Claude opens these with Read), or **not available** (with the reason). Folders are rescanned before each request, so edits and new files are picked up automatically. **Verify** asks Claude, in the chat, to list the documents it can see.
- The main window shows the one shared conversation. Quick chat, window checks and main-window messages all go to the same Claude session, which survives relaunches. **Reset Conversation** clears the chat and starts a new session; the loaded folders stay.
- Double-tap either Option key to open the chat overlay. Return sends, Shift-Return adds a line, Escape or a click outside closes it. Paste images with Command-V. Drag the card to move it; the position is remembered.
- Press left and right Option together to capture the active app window and check its visible multiple-choice question. The menu-bar circle spins while Claude works, then shows `1`–`4` or `A`–`D`.
- Shortcut's gestures are private to it: bare Option taps that form a gesture, and everything typed or pasted into the overlay (including ⌘ and ⇧), never reach the app or web page underneath. Option used with another key, click or scroll is passed through unchanged. This needs the Accessibility permission.
- Click the menu-bar circle for the last answer and its explanation (or the error, if a check failed), plus Open Chat, Check Active Window, Settings, and Quit.

## Build and run

Requires macOS 14 or later, Xcode command-line tools, and an authenticated `claude` CLI.

```sh
./scripts/build-app.sh
open "dist/Shortcut.app"
```

For permissions to survive rebuilds, run `./scripts/setup-signing.sh` once before building. It creates a self-signed "Shortcut Local Signing" identity in a dedicated keychain. Without it, the build falls back to an ad-hoc signature whose requirement is just the bundle identifier.

On first launch, click the orange permission badges in the main window to grant Accessibility and Screen Recording. macOS may require relaunching the app after permission changes.

If a window check fails, the menu-bar menu shows the reason. Logs: `log stream --predicate 'subsystem == "local.lohzh.Shortcut"'`.

For hands-free QC, launch with `open --env SHORTCUT_QC=1 dist/Shortcut.app`, then trigger gestures with `osascript -l JavaScript -e 'ObjC.import("Foundation"); $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately("local.lohzh.Shortcut.qc.capture", $(), $(), true)'` (also `.qc.chat`, `.qc.close`, `.qc.verify`).

Run tests with:

```sh
swift test
```

## How context reaches Claude

Following Anthropic's guidance (a knowledge base under about 200k tokens can go straight into the prompt), extracted text from PDFs, Word, PowerPoint, notebooks, Markdown and code is written into the system prompt as `<documents>`, ahead of the instructions, and passed with `--system-prompt-file`. The prompt is byte-stable, so it stays in Claude's prompt cache across questions and app relaunches; only the first request after a change (or after the cache expires) pays to load it. Chat and window checks use the same tool set (`Read`, `WebSearch`, `WebFetch`) and send images inline, so a typical answer takes a single model turn. Claude is told to answer from the documents first, then its own knowledge, and to search the web only when neither covers the question. The model is pinned to `opus[1m]`.

## Privacy and security

Claude runs with only `Read`, `WebSearch` and `WebFetch`, read access limited to the reference folders (`--add-dir`), and customizations disabled (`--safe-mode`). The contents of the reference folders, pasted images, the conversation and active-window screenshots are sent to Claude. Captures are deleted after each request; the conversation (with downscaled images) is kept in `~/Library/Application Support/AnswerCircle/Conversation` until you reset it.
