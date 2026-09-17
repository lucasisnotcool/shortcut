#!/bin/zsh
# Maintainer's Mac only: points git at scripts/git-hooks, so every commit,
# pull/merge and rebase on main rebuilds the app, installs it to
# /Applications/Shortcut.app and relaunches it
# (scripts/dev-update.sh). Undo: git config --unset core.hooksPath
set -euo pipefail
cd "${0:A:h:h}"
chmod +x scripts/git-hooks/* scripts/dev-update.sh
git config core.hooksPath scripts/git-hooks
echo "Git hooks installed (core.hooksPath=scripts/git-hooks)."
echo "Builds run in the background; log: ~/Library/Logs/Shortcut/dev-update.log"
