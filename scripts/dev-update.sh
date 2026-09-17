#!/bin/zsh
# Keeps the maintainer's dev copy (dist/Shortcut.app) in step with the code:
# compiles while the app keeps running, then quits it, reassembles and signs
# the bundle, and reopens it if it was running. A failed build leaves the
# running app alone and posts a notification.
#
# Run by the git hooks in scripts/git-hooks (install: scripts/install-dev-hooks.sh)
# after every commit, pull/merge and rebase on main in the main checkout.
# Manual use:  scripts/dev-update.sh [--force] [--foreground]
#   --force       build even off main or in a linked worktree
#   --foreground  don't detach (hooks detach so git returns immediately)
# Log: ~/Library/Logs/Shortcut/dev-update.log.  Disable: SHORTCUT_DEV_UPDATE=0
set -uo pipefail

PROJECT_DIR="${0:A:h:h}"
BUNDLE_ID="io.github.lucasisnotcool.shortcut"
LOG_DIR="$HOME/Library/Logs/Shortcut"
LOG="$LOG_DIR/dev-update.log"
STATE_DIR="$PROJECT_DIR/.build/dev-update"
FORCE=0 FOREGROUND=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        --foreground) FOREGROUND=1 ;;
    esac
done

[[ "${SHORTCUT_DEV_UPDATE:-1}" == "0" ]] && exit 0
cd "$PROJECT_DIR" || exit 0

if (( ! FORCE )); then
    # Only the main checkout on main: worktrees and feature branches would
    # otherwise replace the app with unfinished code.
    [[ "$(git rev-parse --path-format=absolute --git-dir)" == "$(git rev-parse --path-format=absolute --git-common-dir)" ]] || exit 0
    [[ "$(git branch --show-current)" == "main" ]] || exit 0
fi

mkdir -p "$LOG_DIR" "$STATE_DIR"
if (( ! FOREGROUND )); then
    args=(--foreground)
    (( FORCE )) && args+=(--force)
    # Detached, so commits and pulls return at once; git sets GIT_* variables
    # for hooks, which must not leak into the build.
    env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE nohup "$0" "${args[@]}" >>"$LOG" 2>&1 </dev/null &!
    echo "Shortcut dev update started in the background (log: ~/Library/Logs/Shortcut/dev-update.log)"
    exit 0
fi

# One build at a time. A request that arrives mid-build is recorded and
# served by the running build when it finishes.
LOCK="$STATE_DIR/lock"
PENDING="$STATE_DIR/pending"
if ! mkdir "$LOCK" 2>/dev/null; then
    if kill -0 "$(cat "$LOCK/pid" 2>/dev/null)" 2>/dev/null; then
        touch "$PENDING"
        exit 0
    fi
    rm -rf "$LOCK"; mkdir "$LOCK"
fi
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

notify() {
    osascript -e "display notification \"$2\" with title \"Shortcut dev build\" subtitle \"$1\"" >/dev/null 2>&1
}

while true; do
    rm -f "$PENDING"
    COMMIT="$(git rev-parse --short HEAD)"
    echo "=== $(date '+%F %T') building $COMMIT: $(git log -1 --format=%s)"

    if ! swift build -c release --disable-sandbox; then
        echo "=== build failed; the running app was left alone"
        notify "Build failed at $COMMIT" "The running app is unchanged. See ~/Library/Logs/Shortcut/dev-update.log"
        exit 1
    fi

    WAS_RUNNING=0
    if pgrep -qf "$PROJECT_DIR/dist/Shortcut.app/Contents/MacOS/Shortcut"; then
        WAS_RUNNING=1
        osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1
        for _ in {1..50}; do
            pgrep -qf "$PROJECT_DIR/dist/Shortcut.app/Contents/MacOS/Shortcut" || break
            sleep 0.2
        done
    fi

    if ! ./scripts/build-app.sh; then
        echo "=== packaging failed"
        notify "Packaging failed at $COMMIT" "See ~/Library/Logs/Shortcut/dev-update.log"
        exit 1
    fi
    if [[ "$(codesign -dvv dist/Shortcut.app 2>&1)" != *"Authority=Shortcut Local Signing"* ]]; then
        echo "=== warning: not signed with Shortcut Local Signing; permissions will not carry over"
    fi

    if (( WAS_RUNNING )); then
        open "$PROJECT_DIR/dist/Shortcut.app"
        echo "=== relaunched $COMMIT"
    else
        echo "=== built $COMMIT (app was not running; not opened)"
    fi
    notify "Updated to $COMMIT" "$(git log -1 --format=%s | head -c 80)"

    [[ -e "$PENDING" ]] || break
done
