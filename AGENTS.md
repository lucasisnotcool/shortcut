# Setting up Shortcut for a new user: a guide for coding agents

This guide is for a coding agent (Claude Code, Codex or similar) that has been
asked to install Shortcut on someone's Mac. Read it, and README.md, before
running anything. CLAUDE.md is the maintainer's runbook: follow its
invariants whenever you change code, but some of its details (the name, the
bundle id prefix) describe the original author's setup, not the new user's.

## What you are installing

Shortcut is **personal-use software**, not a product:

- It is built from source on the user's own Mac and signed with a self-signed
  certificate created on that Mac. It is not notarized, has no installer and
  no updater, and nobody provides support. Never hand a built `.app` to
  someone else; each person builds their own.
- It drives the user's own `claude` CLI, billed to their own claude.ai
  subscription (and their usage credits, if they enabled them). It does not
  work with an API key; the app removes API-key variables on purpose.
- It sends the reference-folder files, screenshots of the active window,
  pasted images and the chat to Anthropic. The user must be comfortable with
  that for the material they add.
- It is meant for teaching staff: a teacher checking the answer to a quiz
  question they are presenting, against their own course materials. It is not
  for answering an assessment the user is sitting. If the user's intended use
  sounds like that, stop and say so.
- It installs a keyboard event tap (needs Accessibility) and captures windows
  (needs Screen Recording). Only the user can grant those in System Settings.

Tell the user this in plain words before you start.

## Step 1: ask before you build

Use your question tool (AskUserQuestion in Claude Code) rather than
assuming. Confirm at least:

1. **Use case.** What they teach, and how they will use Shortcut: checking
   quiz questions while presenting, quick chat about the course, or both.
2. **Features.** Which of these they want, and whether the defaults suit
   them:
   - Quick chat overlay: double-tap Option.
   - Window check: press left and right Option together; the menu-bar badge
     shows the answer.
   - Reference folders: which course folders to load, and whether they
     contain anything that must not be sent to Anthropic.
   If a gesture clashes with something they already use (another app that
   binds Option, a keyboard remapper), agree on a change before editing
   `GlobalShortcutMonitor.swift`.
3. **Account.** That they have a claude.ai plan and are, or can get, signed in
   to the Claude CLI. Explain that heavy use counts against the plan's limits
   and then usage credits.
4. **Permission to change their Mac.** `scripts/setup-signing.sh` creates a
   new keychain, stores its password under
   `~/Library/Application Support/ShortcutSigning/`, and adds the keychain to
   their search list. Get a yes before running it.
5. **Customisation.** Whether they want the prompts changed (course name,
   tone, language). Prefer the in-app **Prompts…** editor over editing
   `PromptSettings.swift`, so the defaults stay intact.

Keep the answers in mind for the rest of the setup; don't write them into the
repo.

## Step 2: check prerequisites

```sh
sw_vers -productVersion        # needs 14.0 or later; macOS 26+ gets Liquid Glass
xcode-select -p                # Command Line Tools; if missing: xcode-select --install
swift --version                # Swift 6 toolchain
command -v claude && claude auth status
```

`claude auth status` must show that the user is logged in with the
`claude.ai` method. If it doesn't, ask the user to run `claude auth login`
themselves (it opens a browser). The app looks for `claude` in
`~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin` and then `PATH`. If the
CLI is somewhere else, tell the user rather than editing the search list
silently.

`xcode-select --install` opens a system dialog; ask the user to finish it.

## Step 3: build

From the repo root:

```sh
./scripts/setup-signing.sh     # once, after the user agreed (Step 1.4)
./scripts/build-app.sh         # → dist/Shortcut.app
swift test                     # all tests should pass
```

The build must print `Signed with "Shortcut Local Signing".` If it fell back
to an ad-hoc signature, fix signing first: an ad-hoc build loses its
permissions on every rebuild while System Settings still shows them as
granted.

Leave the bundle id (`local.lohzh.AnswerCircle`) as it is unless the user
asks. If they do want their own, change it in both `Resources/Info.plist` and
`scripts/build-app.sh`. The log subsystem and QC notification names
(`local.lohzh.Shortcut…`) are just labels and can stay.

## Step 4: grant permissions (the user does this)

```sh
open dist/Shortcut.app
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
```

Ask the user to switch on **Shortcut** in both panes (the orange badges in
the main window open the same panes), then relaunch:

```sh
osascript -e 'quit app id "local.lohzh.AnswerCircle"'; open dist/Shortcut.app
```

Shortcut is a menu-bar app with no Dock icon. Look for the circle in the menu
bar.

## Step 5: test it on their Mac

Watch the log in a second shell for the whole test (`/usr/bin/log`, because
zsh has a builtin `log`; `--level info` for the permission and answer lines):

```sh
/usr/bin/log stream --level info --predicate 'subsystem == "local.lohzh.Shortcut"'
```

After a relaunch you should see
`Permissions: accessibility=true screenRecording=true claude=true` and a
`Claude CLI auth: method claude.ai` line.

1. **Reference folders.** Ask the user to add their course folder in the main
   window. To preview what will load, without the app:
   `SHORTCUT_CONTEXT_DIR="<folder>" swift test --filter reportRealFolder`
   (it prints `CTX` lines). Files over the ~200k-token budget, images and
   scanned PDFs are read on demand; Keynote, Pages and `.ppt` files need
   exporting to PDF or `.pptx` first.
2. **Hands-free checks.** Relaunch with the QC hooks and trigger each action:

   ```sh
   osascript -e 'quit app id "local.lohzh.AnswerCircle"'
   open --env SHORTCUT_QC=1 dist/Shortcut.app
   qc() { osascript -l JavaScript -e "ObjC.import('Foundation'); \$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately('local.lohzh.Shortcut.qc.$1', \$(), \$(), true)"; }
   qc verify     # Claude lists the documents it can see (main window chat)
   qc chat       # opens the overlay
   qc close
   ```

   For a window check, write a small local HTML page with one multiple-choice
   question whose answer you know, open it in the browser, bring the browser
   to the front, then run `qc capture`. The log should show
   `Window answer: single B` (or whatever the answer is), and the menu-bar
   badge should show it.
3. **What only the user can check.** Your terminal usually has no Screen
   Recording permission, so `screencapture` fails and you can't see the
   screen. Ask the user to try these and tell you the result:
   - double-tap Option, type a question, press Return, and check the reply is
     readable over both a light and a dark window;
   - press both Option keys over a real quiz and compare the badge with the
     correct answer;
   - in a text field of another app, check that the gestures type nothing and
     that Option-letter shortcuts still work.

Don't report the setup as done until the user has confirmed these checks.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Gestures do nothing, or keys leak to other apps | Accessibility not granted to *this* build. Remove Shortcut from the list, re-add `dist/Shortcut.app`, relaunch. `tccutil reset Accessibility local.lohzh.AnswerCircle` clears a stale grant. |
| Window check fails with a capture error | Same for Screen Recording (`tccutil reset ScreenCapture local.lohzh.AnswerCircle`). |
| Permissions shown as on but ignored after a rebuild | The build was signed ad-hoc. Run `setup-signing.sh`, rebuild, re-grant. |
| "Claude CLI not found" | Install the CLI in one of the searched locations (Step 2). |
| Main window says signed in with something other than a subscription | `claude auth logout`, then `claude auth login` with the claude.ai account. |
| Answers ignore the course files | Check the sidebar statuses, then `qc verify`. The exact prompt sent is at `~/Library/Application Support/AnswerCircle/system-prompt.md`. |

## Updating and removing

Update: `git pull`, `./scripts/build-app.sh`, relaunch. The grants survive,
because the signing identity doesn't change.

Remove, after the user confirms:

```sh
osascript -e 'quit app id "local.lohzh.AnswerCircle"'
tccutil reset All local.lohzh.AnswerCircle
defaults delete local.lohzh.AnswerCircle
rm -rf dist "$HOME/Library/Application Support/AnswerCircle"
# Signing identity, only if nothing else uses it:
security delete-keychain "$HOME/Library/Keychains/shortcut-signing.keychain-db"
rm -rf "$HOME/Library/Application Support/ShortcutSigning"
```
