# CLAUDE.md — Shortcut runbook for Claude Code

Shortcut is a private macOS menu-bar assistant for teaching: it checks the
multiple-choice question on screen against the course materials while Lucas
presents. Answers come from a ranked model list (Claude Code by default, plus
BYOK API providers and local models). It is built, signed and in daily use on Lucas's Mac. Read README.md
first for what exists.

**Setting Shortcut up for someone else, or on another Mac?** Read AGENTS.md
first: it is personal-use software, and the guide says what to ask the user,
how to build and grant permissions, and how to test it with them.

## Orientation

- App: SwiftPM package, SwiftUI + AppKit, zero dependencies. The target and
  test target are still named `AnswerCircle` (the original name); the product,
  executable and bundle are `Shortcut`.
- Distribution: public GitHub repo, signed DMG on GitHub Releases
  (INSTALL.md for users, RELEASING.md for cutting a release with
  `scripts/release.sh X.Y.Z`). Releases must be signed with the same
  "Shortcut Local Signing" certificate every time, or users lose their
  permissions. CI (`.github/workflows/ci.yml`) tests and builds unsigned.
- First run for downloaded copies: `SetupAssistant` (welcome notice, move
  out of the DMG, Claude CLI install and sign-in through `.command` files in
  Terminal) and the **Finish setting up** checklist in the sidebar.
  `UpdateChecker` polls the public releases API daily and never downloads.
- Build: `./scripts/build-app.sh [--universal]` → `dist/Shortcut.app`, signed with the
  self-signed "Shortcut Local Signing" identity from
  `scripts/setup-signing.sh` (dedicated keychain
  `~/Library/Keychains/shortcut-signing.keychain-db`). Never ship an ad-hoc
  build: macOS keys the Screen Recording and Accessibility grants on the
  signature, and an ad-hoc one changes every build.
- **Dev auto-update (maintainer's Mac):** `core.hooksPath` is
  `scripts/git-hooks`, so every commit, pull/merge and rebase on `main` in
  the main checkout runs `scripts/dev-update.sh` in the background. It
  compiles, quits the running app, rebuilds and signs `dist/Shortcut.app`,
  installs it to `/Applications/Shortcut.app` (the copy the maintainer
  runs; System Settings' pickers only find apps there), and reopens it if it
  was running; a failed build leaves the app alone and
  posts a notification. Log: `~/Library/Logs/Shortcut/dev-update.log`.
  Worktrees and other branches are skipped. Expect the app to restart after
  you commit; prefix a command with `SHORTCUT_DEV_UPDATE=0` to skip (e.g.
  during QC runs). Reinstall with `scripts/install-dev-hooks.sh`. Don't
  install the release DMG on this Mac: it would replace the dev copy.
- Models: `ModelConfig.swift` (`ProviderKind` presets, `ModelEntry`,
  `ModelStore` in the `Shortcut.Models` default, `KeychainKeyStore`),
  `LLMClients.swift` (Anthropic, OpenAI-compatible, Gemini and Ollama
  clients, `ProviderError` classification, `ModelCatalog` listing/testing),
  `ModelRouter.swift` (fallback, cooldowns, transcript replay, CLI catch-up),
  `ReferenceReader.swift` (the sandboxed Read tool), `ModelsView.swift`
  (the Models… sheet). Tests use `ScriptedTransport` and `StubCLI`; no test
  touches the network or the Keychain.
- Relaunch: `osascript -e 'quit app id "io.github.lucasisnotcool.shortcut"'; open dist/Shortcut.app`.
  The bundle id is `io.github.lucasisnotcool.shortcut` (`AppIdentity`);
  it was `local.lohzh.AnswerCircle` before 1.0, and `AppIdentity` migrates
  that id's defaults and the old `AnswerCircle` support folder once at launch.
- Docs for humans: `docs/FEATURES.md` (screenshots in `docs/images`, taken
  with the mock course and quiz pages in `docs/demo`; never use real course
  material in them).
- Icon: `Resources/AppIcon.icns`, drawn by `scripts/make-icon.swift`;
  regenerate with `./scripts/make-icon.sh`.
- Tests: `swift test`. `SHORTCUT_SNAPSHOT_DIR=<dir>` renders the overlay and
  main window to PNGs; `SHORTCUT_CONTEXT_DIR=<folder>` prints a readiness
  report for a real reference folder.
- Logs: `log stream --predicate 'subsystem == "io.github.lucasisnotcool.shortcut"'` — every
  Claude run logs turns, cache reads/writes, cost and model.
- Hands-free QC: `open --env SHORTCUT_QC=1 dist/Shortcut.app`, then post the
  distributed notifications `io.github.lucasisnotcool.shortcut.qc.{chat,capture,close,verify}`
  (README has the one-liner). Never enabled in a normal launch.

## Invariants

1. One conversation for everything (overlay chat, window checks, main
   window), served by `ModelRouter` one request at a time. The CLI keeps
   its own session; API models get the saved chat replayed as text (only
   the current message carries images), and the CLI gets the turns other
   models answered since its last reply. Reset clears the conversation,
   starts a new CLI session and clears model cooldowns; the reference
   folders stay.
2. Reference files go into the system prompt (`--system-prompt-file`,
   `<documents>` first, instructions after), not the conversation, so they
   survive resets and stay in the prompt cache. Keep that file byte-stable.
3. Chat and window checks use the same tool list (`Read,WebSearch,WebFetch`
   for the CLI; the `Read` function tool plus the provider's web search for
   API models) and no JSON-schema mode; either difference breaks the cache
   and adds a turn. Images go inline (`--input-format stream-json` for the
   CLI). API models get the same system prompt plus a `<session_setup>` note
   after the instructions, so the documents prefix stays cacheable.
4. Source priority in the prompt: documents → on-demand files → own knowledge
   → web search. Window checks reply with `question_type` first (single,
   multiple, true_false, dropdown, ranking, matching, numeric, fill_blank,
   none); the type decides the other fields and the valid labels (1–8 / A–H
   for choices, 1–20 / A–T for dropdown, ranking and matching, T / F for
   true/false). The reply starts with "question" (which question was
   answered); the prompt picks the first fully visible, unfinished question
   in reading order and forbids mixing options across questions.
   `AnswerKind` / `AnswerTag` in WindowAnswer.swift own the
   badge text, titles and chat header; messages store the tag. The parser
   still accepts the old `selected_option` format and old saved chats.
9. The CLI must bill the claude.ai subscription (usage credits cover
   overflow): `ClaudeService.childEnvironment()` strips API-key, base-URL and
   cloud-provider variables. BYOK keys live only in the Keychain (service
   `io.github.lucasisnotcool.shortcut.api-keys`, account = provider raw
   value, or `custom-<uuid>`), never in defaults, logs or the CLI env. `claude auth status` is logged at launch and
   shown in the main window. The instructions and the
   window-check prompt live in `PromptSettings` (defaults there, user edits in
   `Shortcut.Prompt.*` defaults, editable via Prompts… in the main window);
   the reply format and documents block are not editable. Keep the default
   instructions byte-stable unless the change is intended: any edit reloads
   the cache.
5. The default (and migrated) model list is a single Claude Code entry
   with `opus[1m]`. New models are appended to the bottom. Fallback happens
   on any request failure (transient errors retry once first and put the
   model on a 60 s cooldown; key/quota/not-found errors, 10 min); a
   malformed window-check answer is shown, not retried elsewhere. With one
   model the teacher sees its own error. Window checks and pasted images
   skip models without image input.
6. The UI is monochrome; the menu-bar badge is an outlined template image.
7. The overlay's reply area never shows a scroller (a scroller toggling at the
   height limit caused an endless layout loop with "always show scroll bars").
8. Shortcut consumes its own keys (GlobalShortcutMonitor, an active
   session event tap, needs Accessibility): bare Option presses are held and
   dropped if they form a gesture, replayed before any other key, click,
   scroll or modifier so Option chords work everywhere; while the overlay has
   keyboard focus every modifier change is dropped, because the non-activating
   panel leaves the app underneath active. Verified with a Safari page logging
   key/focus/visibility/clipboard events: it saw nothing from either gesture
   or from typing, ⌥-typing and ⌘V in the overlay. Without Accessibility it
   falls back to listen-only monitors and logs that the keys leak.

## State on disk

- `~/Library/Application Support/Shortcut/system-prompt.md` — the
  generated documents + instructions.
- `~/Library/Application Support/Shortcut/Conversation/` — the saved chat.
- `defaults read io.github.lucasisnotcool.shortcut` — session id, reference folders
  (`Shortcut.ContextRoots`), the model list (`Shortcut.Models`, JSON),
  overlay position, welcome/update/migration flags.
