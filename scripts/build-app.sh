#!/bin/zsh
# Builds dist/Shortcut.app.
#   --universal   Apple silicon + Intel (release builds); default is this Mac's arch.
# SHORTCUT_VERSION=1.2.0 stamps a version into the bundle instead of Info.plist's.
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"

ARCH_FLAGS=()
[[ "${1:-}" == "--universal" ]] && ARCH_FLAGS=(--arch arm64 --arch x86_64)

swift build -c release --disable-sandbox "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c release --show-bin-path "${ARCH_FLAGS[@]}")"

APP_DIR="$PROJECT_DIR/dist/Shortcut.app"
CONTENTS_DIR="$APP_DIR/Contents"
PLIST="$CONTENTS_DIR/Info.plist"

/bin/rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$BIN_DIR/Shortcut" "$CONTENTS_DIR/MacOS/Shortcut"
cp "$PROJECT_DIR/Resources/Info.plist" "$PLIST"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"

if [[ -n "${SHORTCUT_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SHORTCUT_VERSION" "$PLIST"
fi
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"

# macOS ties Screen Recording / Accessibility grants to the app's designated
# requirement. With the certificate-backed identity that is "this bundle id,
# signed by this certificate", so every release keeps the grants. A plain
# ad-hoc signature changes it on every build, which silently revokes them.
IDENTITY="Shortcut Local Signing"
KEYCHAIN="$HOME/Library/Keychains/shortcut-signing.keychain-db"
PASSWORD_FILE="$HOME/Library/Application Support/ShortcutSigning/keychain-password"
if [[ -f "$PASSWORD_FILE" ]] && security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY"; then
    security unlock-keychain -p "$(cat "$PASSWORD_FILE")" "$KEYCHAIN"
    codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --identifier "$BUNDLE_ID" "$APP_DIR"
    echo "Signed with \"$IDENTITY\"."
else
    codesign --force --sign - --identifier "$BUNDLE_ID" \
        -r="designated => identifier \"$BUNDLE_ID\"" "$APP_DIR"
    echo "Signed ad-hoc with a stable requirement (run scripts/setup-signing.sh for a certificate-backed identity)."
fi

echo "Shortcut $VERSION ($(lipo -archs "$CONTENTS_DIR/MacOS/Shortcut")): $APP_DIR"
