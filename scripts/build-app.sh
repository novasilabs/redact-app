#!/bin/sh
# Builds build/Redact.app (release, ad-hoc signed) with the `redact` CLI inside it.
#   scripts/build-app.sh            release build
#   scripts/build-app.sh debug      debug build
set -eu
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG" --product RedactApp
swift build -c "$CONFIG" --product redact
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/Redact.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cp "$BIN/RedactApp" "$APP/Contents/MacOS/Redact"
cp "$BIN/redact" "$APP/Contents/Resources/bin/redact"
# Icon: regenerate with `swift scripts/make-icon.swift`.
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

VERSION="0.1.0"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.redact.app</string>
  <key>CFBundleName</key><string>Redact</string>
  <key>CFBundleDisplayName</key><string>Redact</string>
  <key>CFBundleExecutable</key><string>Redact</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Redact Backup</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>LSItemContentTypes</key><array><string>dev.redact.backup</string></array>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>dev.redact.backup</string>
      <key>UTTypeDescription</key><string>Redact Backup</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>redact</string></array></dict>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Ad-hoc signature until there is a Developer ID (see spikes/FINDINGS.md §5).
codesign --force --sign - --identifier dev.redact.cli "$APP/Contents/Resources/bin/redact"
codesign --force --sign - --identifier dev.redact.app "$APP"
echo "Built $APP"
echo "CLI:   $APP/Contents/Resources/bin/redact"
