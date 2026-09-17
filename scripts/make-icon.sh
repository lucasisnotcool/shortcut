#!/bin/zsh
# Regenerates Resources/AppIcon.icns from scripts/make-icon.swift.
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
WORK="$(mktemp -d)"
trap '/bin/rm -rf "$WORK"' EXIT

swift "$PROJECT_DIR/scripts/make-icon.swift" "$WORK/AppIcon.iconset"
iconutil -c icns "$WORK/AppIcon.iconset" -o "$PROJECT_DIR/Resources/AppIcon.icns"
echo "$PROJECT_DIR/Resources/AppIcon.icns"
