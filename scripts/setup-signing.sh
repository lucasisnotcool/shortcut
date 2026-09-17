#!/bin/zsh
# One-time setup: creates a self-signed "Shortcut Local Signing" code-signing
# identity in a dedicated keychain, so rebuilt copies of Shortcut keep their
# Screen Recording and Accessibility permissions.
#
#   scripts/setup-signing.sh                      create a new certificate
#   scripts/setup-signing.sh --import backup.p12  restore the release certificate
#                                                 (asks for the backup's passphrase)
set -euo pipefail

IMPORT="${2:-}"
if [[ "${1:-}" == "--import" ]]; then
    [[ -f "$IMPORT" ]] || { echo "usage: scripts/setup-signing.sh --import <file.p12>" >&2; exit 1; }
    read -rs "IMPORT_PASS?Passphrase for $IMPORT: "; echo
fi

IDENTITY="Shortcut Local Signing"
KEYCHAIN="$HOME/Library/Keychains/shortcut-signing.keychain-db"
SUPPORT="$HOME/Library/Application Support/ShortcutSigning"
PASSWORD_FILE="$SUPPORT/keychain-password"

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY"; then
    echo "Signing identity already set up."
    exit 0
fi

WORK="$(mktemp -d)"
trap '/bin/rm -rf "$WORK"' EXIT
P12_PASS=shortcut
if [[ -n "$IMPORT" ]]; then
    cp "$IMPORT" "$WORK/id.p12"
    P12_PASS="$IMPORT_PASS"
else

cat > "$WORK/cert.cnf" <<'EOF'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=Shortcut Local Signing
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/id.p12" -passout pass:shortcut -name "$IDENTITY"
fi

mkdir -p "$SUPPORT"
chmod 700 "$SUPPORT"
openssl rand -hex 24 | tr -d '\n' > "$PASSWORD_FILE"
chmod 600 "$PASSWORD_FILE"
PASSWORD="$(cat "$PASSWORD_FILE")"

security create-keychain -p "$PASSWORD" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
security import "$WORK/id.p12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null

# Add to the user search list so codesign can find the identity.
existing=("${(@f)$(security list-keychains -d user | sed -e 's/^ *"//' -e 's/"$//')}")
security list-keychains -d user -s "${existing[@]}" "$KEYCHAIN"

echo "${IMPORT:+Imported}${IMPORT:-Created} signing identity \"$IDENTITY\" in $KEYCHAIN"
