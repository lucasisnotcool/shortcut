#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"

swift build -c release --disable-sandbox

APP_DIR="$PROJECT_DIR/dist/Shortcut.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BUNDLE_ID="local.lohzh.AnswerCircle"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$PROJECT_DIR/.build/release/Shortcut" "$MACOS_DIR/Shortcut"
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

# macOS ties Screen Recording / Accessibility grants to the app's designated
# requirement. A plain ad-hoc signature changes it on every build, which
# silently revokes the grants while System Settings still shows them enabled.
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

LEGACY_APP_DIR="$PROJECT_DIR/dist/Answer Circle.app"
if [[ -d "$LEGACY_APP_DIR" ]]; then
    /bin/rm -rf "$LEGACY_APP_DIR"
fi

echo "$APP_DIR"
