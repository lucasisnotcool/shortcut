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
   → web search. Window checks may answer `NONE`.
5. The model is pinned to `opus[1m]`.
6. The UI is monochrome; the menu-bar badge is an outlined template image.
7. The overlay's reply area never shows a scroller (a scroller toggling at the
   height limit caused an endless layout loop with "always show scroll bars").

## State on disk

- `~/Library/Application Support/AnswerCircle/system-prompt.md` — the
  generated documents + instructions.
- `~/Library/Application Support/AnswerCircle/Conversation/` — the saved chat.
- `defaults read local.lohzh.AnswerCircle` — session id, reference folders
  (`Shortcut.ContextRoots`), overlay position.
