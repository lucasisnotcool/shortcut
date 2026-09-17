# Releasing Shortcut

Releases are built and signed on the maintainer's Mac and published as a DMG
on GitHub Releases. There is no Apple Developer ID: the app is signed with
the self-signed **Shortcut Local Signing** certificate from
`scripts/setup-signing.sh`.

## The signing certificate is the release key

macOS keys each user's Accessibility and Screen Recording grants on the app's
designated requirement:

```
identifier "io.github.lucasisnotcool.shortcut" and certificate leaf = H"4790…5f80"
```

Every release must be signed by **the same certificate**. A release signed
by a different one still opens, but every user silently loses both
permissions and has to grant them again. So:

- **Back it up now**, and keep the backup somewhere private (never in the repo):

  ```sh
  security unlock-keychain -p "$(cat ~/Library/Application\ Support/ShortcutSigning/keychain-password)" \
      ~/Library/Keychains/shortcut-signing.keychain-db
  security export -k ~/Library/Keychains/shortcut-signing.keychain-db \
      -t identities -f pkcs12 -P '<a strong passphrase>' -o ~/Desktop/shortcut-signing.p12
  ```

  On a new Mac, restore it with
  `scripts/setup-signing.sh --import shortcut-signing.p12` (plain
  `setup-signing.sh` would make a *new* certificate).
  `scripts/release.sh` refuses to run without the identity.
- The certificate is valid until September 2036.
- Moving to a Developer ID later also changes the requirement. Announce it
  in the release notes, since users will re-grant permissions once.

## Your own copy

On the maintainer's Mac, run `scripts/install-dev-hooks.sh` once. After that
every commit, pull and rebase on `main` rebuilds `dist/Shortcut.app` and
relaunches it (details in `scripts/dev-update.sh`). Use that copy, not the
DMG, so there is only one Shortcut on the Mac.

## Cutting a release

```sh
scripts/release.sh 1.1.0            # creates a draft release
scripts/release.sh 1.1.0 --publish  # publishes straight away
```

The script:

1. checks you are on a clean `main`, the tag is new, `gh` is signed in, and
   the signing identity exists;
2. sets `CFBundleShortVersionString` to the version and increments
   `CFBundleVersion` in `Resources/Info.plist`;
3. runs `swift test`, builds a universal (arm64 + x86_64) app, verifies the
   signature, and packages `dist/Shortcut-<version>.dmg` plus its `.sha256`;
4. commits "Release <version>", tags `v<version>`, and pushes both;
5. creates the GitHub release with the DMG, the checksum, install
   instructions and generated notes.

Check the draft on GitHub (download the DMG, open it on a Mac, confirm the
version in the menu-bar menu's update check), then click **Publish**. The
in-app update check only sees published, non-prerelease releases.

## Testing a build like a new user

```sh
scripts/build-app.sh --universal && scripts/make-dmg.sh
xattr -w com.apple.quarantine "0081;$(printf %x $(date +%s));Safari;" dist/Shortcut-*.dmg
open dist/Shortcut-*.dmg
```

The quarantine flag makes macOS treat the DMG as downloaded, so you see the
Gatekeeper prompt, the move-to-Applications offer and the welcome notice.
Use a separate macOS user account for a truly clean run (no saved settings
and no grants). To see the welcome again in your own account, run
`defaults delete io.github.lucasisnotcool.shortcut Shortcut.AcceptedWelcome`.
