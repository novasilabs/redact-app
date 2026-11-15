#!/bin/sh
# Builds build/Redact-<version>.dmg: the universal release app, an Applications shortcut, and a
# "Read me first" note on opening an app that isn't notarized by Apple.
#   scripts/make-dmg.sh            version from REDACT_VERSION, default 0.1.0
set -eu
cd "$(dirname "$0")/.."

VERSION="${REDACT_VERSION:-0.1.0}"
REDACT_VERSION="$VERSION" ./scripts/build-app.sh release

STAGE="$(mktemp -d -t redact-dmg)"
trap 'rm -rf "$STAGE"' EXIT
cp -R build/Redact.app "$STAGE/Redact.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read me first.txt" <<NOTE
Redact $VERSION

1. Drag Redact into Applications.

2. Open it the first time. Redact isn't notarized by Apple (no paid developer account), so macOS
   stops it once:
   - macOS 15 or later: open Redact, click Done, then go to System Settings > Privacy & Security,
     scroll down and click "Open Anyway" next to Redact.
   - macOS 14: right-click Redact in Applications, choose Open, then Open again.
   Or in Terminal:  xattr -dr com.apple.quarantine /Applications/Redact.app

3. In Redact: create your vault and save the Recovery Key. Then choose Redact > Set Up Terminal…
   so the redact command and rr work in your terminal.

Check the download: shasum -a 256 Redact-$VERSION.dmg should match the published checksum.
Redact keeps your secrets on this Mac only. Source and license (MIT): see README.
NOTE

DMG="build/Redact-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Redact $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
