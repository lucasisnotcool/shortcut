# Shortcut

A private, native macOS menu-bar assistant backed by the locally installed Claude CLI, or by your own API keys (Anthropic, OpenAI, Gemini, OpenRouter and more) and local models (Ollama, LM Studio). While you present a quiz, it reads the question on screen, answers it from your course files, and shows the answer to you alone in the menu bar.

https://github.com/user-attachments/assets/f2bd6850-dc85-43fd-a17b-516d93c196d7

![A demo quiz question on the left and Shortcut's answer, B, with its reasoning on the right](docs/images/check-single.png)

**[See what it does, with screenshots of every question type →](docs/FEATURES.md)** (all demo content)

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
- **Models…** (chat header in the main window, or click the model name in the sidebar) holds the ranked model list. The first available model answers; if it fails (rate limit, outage, timeout, rejected key, context too long) the next one takes over, and the reply is labelled with the model that wrote it. Drag to reorder; new models go to the bottom; switch one off to skip it. Each model has its provider, model id (**Fetch List** asks the provider), server address, API key (kept in the login keychain, shared by a provider's models), image input, Read tool, web search, context window, reply length, temperature and extra headers, plus **Test Connection**, which sends a one-word request with a small image. Window checks and pasted images skip models without image input. Providers: Claude Code (subscription), Anthropic, OpenAI, Google Gemini, OpenRouter, xAI, Mistral, Groq, DeepSeek, Azure OpenAI, Ollama, LM Studio, and any OpenAI-compatible server.
- **Prompts…** (chat header in the main window) shows what is sent to Claude and lets you edit the Session Instructions (system prompt, after the reference documents) and the Window Check prompt. Edits apply from the next request without a reset; the JSON reply format and the generated documents stay fixed. **Restore Default** undoes an edit. The exact system prompt of the latest request is at `~/Library/Application Support/Shortcut/system-prompt.md`.
- Click the menu-bar circle for the last answer and its explanation (or the error, if a check failed), plus Open Chat, Check Active Window, Settings, Check for Updates, and Quit.

## Install

**[Download the latest DMG](https://github.com/lucasisnotcool/shortcut/releases/latest)**, drag Shortcut to Applications, and follow **[INSTALL.md](INSTALL.md)**. You need macOS 14 or later and either a claude.ai Pro or Max plan or an API key (a local Ollama or LM Studio model also works). The app isn't notarized, so the first launch needs **Open Anyway** in Privacy & Security. After that, a **Finish setting up** checklist in the app installs and signs in to Claude Code (or points you to **Models…** for an API key) and asks for the two permissions.

Shortcut is free, personal-use software with no support. It is meant for teaching staff checking questions they present, not for answering an assessment you are taking.

## Build from source

Requires macOS 14 or later and Xcode 26 or later (the overlay uses the macOS 26 SDK).

```sh
./scripts/setup-signing.sh      # once: self-signed identity so permissions survive rebuilds
./scripts/build-app.sh          # → dist/Shortcut.app (add --universal for arm64 + x86_64)
open dist/Shortcut.app
```

Without `setup-signing.sh`, the build falls back to an ad-hoc signature whose requirement is just the bundle identifier. A coding agent can do the whole setup with you: [AGENTS.md](AGENTS.md) tells it what to confirm, build, grant and test. `./scripts/make-dmg.sh` packages the app; [RELEASING.md](RELEASING.md) covers releases.

The app icon is drawn by `scripts/make-icon.swift`; `./scripts/make-icon.sh` regenerates `Resources/AppIcon.icns`.

If a window check fails, the menu-bar menu shows the reason. Logs: `log stream --predicate 'subsystem == "io.github.lucasisnotcool.shortcut"'`.

For hands-free QC, launch with `open --env SHORTCUT_QC=1 dist/Shortcut.app`, then trigger gestures with `osascript -l JavaScript -e 'ObjC.import("Foundation"); $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately("io.github.lucasisnotcool.shortcut.qc.capture", $(), $(), true)'` (also `.qc.chat`, `.qc.close`, `.qc.verify`).

Run tests with:

```sh
swift test
```

## How context reaches the model

Following Anthropic's guidance (a knowledge base under about 200k tokens can go straight into the prompt), extracted text from PDFs, Word, PowerPoint, notebooks, Markdown and code is written into the system prompt as `<documents>`, ahead of the instructions, and passed with `--system-prompt-file`. The prompt is byte-stable, so it stays in Claude's prompt cache across questions and app relaunches; only the first request after a change (or after the cache expires) pays to load it. Chat and window checks use the same tool set (`Read`, `WebSearch`, `WebFetch`) and send images inline, so a typical answer takes a single model turn. Claude is told to answer from the documents first, then its own knowledge, and to search the web only when neither covers the question. The default model is Claude Code with `opus[1m]`.

API models get the same system prompt (documents first, then the instructions, then a short note on which tools this model has), with prompt caching where the provider offers it (Anthropic's `cache_control`; OpenAI, Gemini and others cache automatically). They are stateless, so Shortcut replays the saved conversation as text; only the current message carries its images. With a context window set, the oldest turns are dropped to fit, and a model too small for the documents is skipped. On-demand files are opened through a read-only `Read` function tool limited to the reference folders (scanned PDF pages come back as images); models that reject tools are retried without them. Web search uses Anthropic's web search tool, Gemini's Google Search grounding, or OpenRouter's web plugin, when switched on. Ollama is called through its native `/api/chat` so the context size (`num_ctx`) can be set per request. When Claude Code answers after other models did, the turns it missed are included in its message.

## Billing

With the Claude Code model, Shortcut runs the Claude CLI signed in with your claude.ai account (the main window shows the plan and email under the model). Requests count toward the plan's limits; with usage credits enabled in claude.ai **Settings › Usage**, they continue past those limits at API rates, up to your monthly cap. Shortcut removes `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL` and the Bedrock/Vertex/Foundry switches from the CLI's environment so requests always go through the subscription. API models bill the provider account whose key you added; Shortcut logs token usage for each reply but does not track spend.

## Privacy and security

Claude Code runs with only `Read`, `WebSearch` and `WebFetch`, read access limited to the reference folders (`--add-dir`), and customizations disabled (`--safe-mode`). The contents of the reference folders, pasted images, the conversation and active-window screenshots are sent to the model that answers: to Anthropic for Claude Code, and to the provider you configured for an API model (fallbacks included). Local models keep them on your Mac. API keys are stored in the login keychain (service `io.github.lucasisnotcool.shortcut.api-keys`), never in preferences. Captures are deleted after each request; the conversation (with downscaled images) is kept in `~/Library/Application Support/Shortcut/Conversation` until you reset it.

Apart from the models you configure, Shortcut contacts only GitHub's public releases API, once a day, to check for a new version (turn off **Check Automatically** in the menu-bar menu). It sends no information about you.

## License

MIT, see [LICENSE](LICENSE). Shortcut is not affiliated with Anthropic.
