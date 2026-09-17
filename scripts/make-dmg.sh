#!/bin/zsh
# Packages dist/Shortcut.app into dist/Shortcut-<version>.dmg (with an
# Applications link to drag onto) and writes its SHA-256 next to it.
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP_DIR="$PROJECT_DIR/dist/Shortcut.app"
[[ -d "$APP_DIR" ]] || { echo "Build first: scripts/build-app.sh --universal" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")"
DMG="$PROJECT_DIR/dist/Shortcut-$VERSION.dmg"
STAGING="$(mktemp -d)"
trap '/bin/rm -rf "$STAGING"' EXIT

ditto "$APP_DIR" "$STAGING/Shortcut.app"
ln -s /Applications "$STAGING/Applications"

/bin/rm -f "$DMG"
hdiutil create -quiet -volname "Shortcut $VERSION" -srcfolder "$STAGING" \
    -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG"

IDENTITY="Shortcut Local Signing"
KEYCHAIN="$HOME/Library/Keychains/shortcut-signing.keychain-db"
if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" "$DMG"
fi

(cd "${DMG:h}" && shasum -a 256 "${DMG:t}" > "${DMG:t}.sha256")
echo "$DMG"
