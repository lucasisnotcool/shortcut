#!/bin/zsh
# Cuts a release: bumps the version, tests, builds a universal signed app,
# packages the DMG, commits, tags, pushes, and creates a DRAFT GitHub release
# with the DMG attached. Review the draft on GitHub, then publish it there
# (or pass --publish). Only a published release reaches the in-app update check.
#
#   scripts/release.sh 1.1.0 [--publish]
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"

VERSION="${1:-}"
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "usage: scripts/release.sh X.Y.Z [--publish]" >&2; exit 1; }
DRAFT=(--draft)
[[ "${2:-}" == "--publish" ]] && DRAFT=()
TAG="v$VERSION"
PLIST="Resources/Info.plist"

# Preconditions
[[ "$(git branch --show-current)" == "main" ]] || { echo "Release from main." >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first." >&2; exit 1; }
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "$TAG already exists." >&2; exit 1; }
gh auth status >/dev/null
security find-identity -p codesigning "$HOME/Library/Keychains/shortcut-signing.keychain-db" 2>/dev/null \
    | grep -q "Shortcut Local Signing" \
    || { echo "The signing identity is missing. Releases must be signed with the same certificate every time, or users lose their permissions. Restore it from your backup (see RELEASING.md)." >&2; exit 1; }

# Version: marketing version from the argument, build number +1.
BUILD=$(( $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST") + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$PLIST"

swift test
./scripts/build-app.sh --universal
codesign --verify --strict "dist/Shortcut.app"
./scripts/make-dmg.sh
DMG="dist/Shortcut-$VERSION.dmg"

git commit -m "Release $VERSION" -- "$PLIST"
git tag -a "$TAG" -m "Shortcut $VERSION"
git push origin main "$TAG"

NOTES="$(mktemp)"
trap '/bin/rm -f "$NOTES"' EXIT
cat > "$NOTES" <<EOF
## Install

1. Download **Shortcut-$VERSION.dmg**, open it and drag **Shortcut** to **Applications**.
2. Open Shortcut. macOS blocks it the first time because it isn't notarized: open **System Settings › Privacy & Security**, scroll down and click **Open Anyway** next to the message about Shortcut.
3. Follow **Finish setting up** in the Shortcut window (Claude Code, sign-in, Accessibility, Screen Recording).

Updating from an earlier version: quit Shortcut, replace the app in Applications, open it again. Settings and permissions carry over.

Requires macOS 14 or later and a claude.ai Pro or Max plan. Full guide: [INSTALL.md](https://github.com/lucasisnotcool/shortcut/blob/$TAG/INSTALL.md)

SHA-256: \`$(cut -d' ' -f1 "$DMG.sha256")\`
EOF

gh release create "$TAG" "$DMG" "$DMG.sha256" "${DRAFT[@]}" \
    --title "Shortcut $VERSION" --notes-file "$NOTES" --generate-notes --verify-tag
echo "Release $TAG created${DRAFT:+ as a draft}: $(gh release view "$TAG" --json url -q .url)"
