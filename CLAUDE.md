# CLAUDE.md — Shortcut runbook for Claude Code

Shortcut is a private macOS menu-bar assistant for teaching: it checks the
multiple-choice question on screen against the course materials while Lucas
presents. It is built, signed and in daily use on this Mac. Read README.md
first for what exists.

## Orientation

- App: SwiftPM package, SwiftUI + AppKit, zero dependencies. The target and
  test target are still named `AnswerCircle` (the original name); the product,
  executable and bundle are `Shortcut`.
- Build: `./scripts/build-app.sh` → `dist/Shortcut.app`, signed with the
  self-signed "Shortcut Local Signing" identity from
  `scripts/setup-signing.sh` (dedicated keychain
  `~/Library/Keychains/shortcut-signing.keychain-db`). Never ship an ad-hoc
  build: macOS keys the Screen Recording and Accessibility grants on the
  signature, and an ad-hoc one changes every build.
- Relaunch: `osascript -e 'quit app id "local.lohzh.AnswerCircle"'; open dist/Shortcut.app`.
  The bundle id stays `local.lohzh.AnswerCircle` so existing grants and
  defaults survive.
- Tests: `swift test`. `SHORTCUT_SNAPSHOT_DIR=<dir>` renders the overlay and
  main window to PNGs; `SHORTCUT_CONTEXT_DIR=<folder>` prints a readiness
  report for a real reference folder.
- Logs: `log stream --predicate 'subsystem == "local.lohzh.Shortcut"'` — every
  Claude run logs turns, cache reads/writes, cost and model.
- Hands-free QC: `open --env SHORTCUT_QC=1 dist/Shortcut.app`, then post the
  distributed notifications `local.lohzh.Shortcut.qc.{chat,capture,close,verify}`
  (README has the one-liner). Never enabled in a normal launch.

## Invariants

1. One Claude session for everything (overlay chat, window checks, main
   window). Reset clears the conversation and starts a new session; the
   reference folders stay.
2. Reference files go into the system prompt (`--system-prompt-file`,
   `<documents>` first, instructions after), not the conversation, so they
   survive resets and stay in the prompt cache. Keep that file byte-stable.
3. Chat and window checks use the same tool list (`Read,WebSearch,WebFetch`)
   and no `--json-schema`; either difference breaks the cache and adds a turn.
   Images go inline via `--input-format stream-json`.
4. Source priority in the prompt: documents → on-demand files → own knowledge
   → web search. Window checks reply with `question_type` (single, multiple,
   true_false, none) first and a verdict per option; the type decides which
   labels are valid (1–8 / A–H, or T / F — "F" is ambiguous otherwise), and
   the answer set is the options marked `is_answer`. The parser still accepts
   the old `selected_option` format. The instructions and the
   window-check prompt live in `PromptSettings` (defaults there, user edits in
   `Shortcut.Prompt.*` defaults, editable via Prompts… in the main window);
   the reply format and documents block are not editable. Keep the default
   instructions byte-stable unless the change is intended: any edit reloads
   the cache.
5. The model is pinned to `opus[1m]`.
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

- `~/Library/Application Support/AnswerCircle/system-prompt.md` — the
  generated documents + instructions.
- `~/Library/Application Support/AnswerCircle/Conversation/` — the saved chat.
- `defaults read local.lohzh.AnswerCircle` — session id, reference folders
  (`Shortcut.ContextRoots`), overlay position.
