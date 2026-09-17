# Shortcut

A private, native macOS menu-bar assistant backed by the locally installed Claude CLI.

## Interactions

- Add a course folder in the main window (sidebar). Every file inside, including subfolders, is loaded straight into Claude's context, and the sidebar shows each file's status: **in context** (with a token estimate), **on demand** (images, scanned PDFs, or anything over the 200k-token budget; Claude opens these with Read), or **not available** (with the reason). Folders are rescanned before each request, so edits and new files are picked up automatically. **Verify** asks Claude, in the chat, to list the documents it can see.
- The main window shows the one shared conversation. Quick chat, window checks and main-window messages all go to the same Claude session, which survives relaunches. **Reset Conversation** clears the chat and starts a new session; the loaded folders stay.
- Double-tap either Option key to open the chat overlay. Return sends, Shift-Return adds a line, Escape or a click outside closes it. Paste images with Command-V. Drag the card to move it; the position is remembered.
- Press left and right Option together to capture the active app window and answer the quiz question on it. The menu-bar circle spins while Claude works, then shows:

  | Question | Badge | Example |
  |---|---|---|
  | Single answer | the option in a ring | `B` |
  | Multiple response | every correct option in a capsule | `1 3 4` |
  | True/false | `T` or `F` | `F` |
  | Dropdown blank (list open) | the option's position in the list, from the top | `3` |
  | Ranking | the options first to last | `3 2 5 4 1` |
  | Matching | the choice for each item, in item order | `B D A C` |
  | Number | the value | `42` |
  | Free-text blanks | `✎`; the text is in the chat and the badge menu | |
  | No confident answer | `!` with the reason | |
  | Error | `×` | |

  With several questions on screen, Claude answers only the first one whose question and options are fully visible, reading top to bottom. It skips cut-off questions and anything already finished above it (leftover options, ticks, "Correct!" feedback), ignores later questions, and gives no answer if no question is complete. The chat and badge menu name the question it answered (for example "Q4 What is the boiling point…").

  Claude judges every option against the question as worded (so "Which are NOT…" is handled per option, and a multiple-response question can have a single answer), bases the answer on the course files, then its own knowledge, then web search, and ignores what is already ticked, highlighted, ordered or connected on screen. The chat and the badge menu show the working: ✓/✗ per option, the ranked list, the pairs, or the text per blank.
- Shortcut's gestures are private to it: bare Option taps that form a gesture, and everything typed or pasted into the overlay (including ⌘ and ⇧), never reach the app or web page underneath. Option used with another key, click or scroll is passed through unchanged. This needs the Accessibility permission.
- **Prompts…** (chat header in the main window) shows what is sent to Claude and lets you edit the Session Instructions (system prompt, after the reference documents) and the Window Check prompt. Edits apply from the next request without a reset; the JSON reply format and the generated documents stay fixed. **Restore Default** undoes an edit. The exact system prompt of the latest request is at `~/Library/Application Support/AnswerCircle/system-prompt.md`.
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

## Billing

Shortcut runs the Claude CLI signed in with your claude.ai account (the main window shows the plan and email under the model). Requests count toward the plan's limits; with usage credits enabled in claude.ai **Settings › Usage**, they continue past those limits at API rates, up to your monthly cap. Shortcut removes `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL` and the Bedrock/Vertex/Foundry switches from the CLI's environment so requests always go through the subscription.

## Privacy and security

Claude runs with only `Read`, `WebSearch` and `WebFetch`, read access limited to the reference folders (`--add-dir`), and customizations disabled (`--safe-mode`). The contents of the reference folders, pasted images, the conversation and active-window screenshots are sent to Claude. Captures are deleted after each request; the conversation (with downscaled images) is kept in `~/Library/Application Support/AnswerCircle/Conversation` until you reset it.
