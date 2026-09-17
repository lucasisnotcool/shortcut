# Installing Shortcut

Shortcut is a free, personal-use macOS app for teaching staff. It checks the
multiple-choice question you are presenting against your own course
materials, using your own Claude subscription. It is not notarized by Apple
and comes with no support.

**You need:** macOS 14 or later, and a claude.ai **Pro or Max** plan.

**Before you start:** Shortcut sends the files in the folders you add,
screenshots of the active window, pasted images and the chat to Anthropic.
Only add material you are allowed to share, and don't use Shortcut to answer
an assessment you are taking.

## 1. Install the app

1. Download `Shortcut-<version>.dmg` from the
   [latest release](https://github.com/lucasisnotcool/shortcut/releases/latest).
2. Open the DMG and drag **Shortcut** onto **Applications**.
3. Open **Shortcut** from Applications. macOS says it can't verify the app,
   because it isn't notarized. Click **Done**.
4. Open **System Settings › Privacy & Security**, scroll down to the message
   about Shortcut, and click **Open Anyway**. Confirm with your password.
   You only do this once; updates open normally.

If you opened Shortcut straight from the DMG, it offers to move itself to
Applications. Accept, because permissions only stick for the copy in
Applications.

Shortcut lives in the menu bar (look for the circle) and has no Dock icon.
Click the circle, then **Shortcut Settings…**, to open its window.

## 2. Finish setting up

The Shortcut window shows a **Finish setting up** checklist until everything
is ready:

| Step | What happens |
|---|---|
| **Install Claude Code** | Opens Terminal and runs Anthropic's installer (`curl -fsSL https://claude.ai/install.sh \| bash`), then starts the sign-in. |
| **Sign in to Claude** | Opens Terminal and runs `claude auth login`. Sign in with your claude.ai account in the browser. API keys are not supported. |
| **Allow Accessibility** | Turn on **Shortcut** in the pane that opens. Needed for the Option-key gestures. |
| **Allow Screen Recording** | Turn on **Shortcut**, then choose **Quit & Reopen** if macOS asks. Needed to read the question on screen. |

Switch back to Shortcut after each step; it checks again by itself (or click
↻ on the checklist).

## 3. Add your course and try it

1. Click **Add…** under **Reference folders** and choose your course folder.
   The list shows which files Claude sees.
2. Click **Verify**. Claude lists the documents it can see.
3. **Double-tap Option** to open the quick chat.
4. With a quiz question on screen, **press both Option keys together**. The
   menu-bar circle spins, then shows the answer.

[docs/FEATURES.md](docs/FEATURES.md) shows every question type.

## Updating

Shortcut checks GitHub for a new release once a day and tells you when one
is out (turn this off in the menu-bar menu under **Check Automatically**).
To update, quit Shortcut, download the new DMG, drag the app to Applications
and choose **Replace**. Your settings, folders, chat and permissions carry
over.

## Troubleshooting

| Symptom | Fix |
|---|---|
| "Shortcut can't be opened" with no **Open Anyway** button | Open the app once from Applications first, then look in Privacy & Security again. |
| The gestures do nothing | Accessibility is off for this copy. In System Settings, remove Shortcut from the list, add `/Applications/Shortcut.app` again, and reopen Shortcut. |
| A window check says it can't capture | The same for Screen Recording. |
| "Not signed in", or signed in with something other than a subscription | Click **Sign In…** in the checklist. |
| Answers ignore your files | Check the file statuses in the sidebar, then click **Verify**. |
| Anything else | Logs: `log stream --predicate 'subsystem == "io.github.lucasisnotcool.shortcut"'` |

## Uninstalling

Quit Shortcut, delete it from Applications, then optionally run:

```sh
tccutil reset All io.github.lucasisnotcool.shortcut
defaults delete io.github.lucasisnotcool.shortcut
rm -rf "$HOME/Library/Application Support/Shortcut"
```

Claude Code stays installed; remove it separately if you no longer need it.
