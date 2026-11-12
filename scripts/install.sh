#!/bin/sh
# Installs Redact for the current user:
#   - copies build/Redact.app to ~/Applications (or the folder in $REDACT_APP_DIR)
#   - links the `redact` CLI into ~/.local/bin (or $REDACT_BIN_DIR)
# Run scripts/build-app.sh first. Nothing is installed system-wide and no sudo is needed.
set -eu
cd "$(dirname "$0")/.."

SRC="build/Redact.app"
APP_DIR="${REDACT_APP_DIR:-$HOME/Applications}"
BIN_DIR="${REDACT_BIN_DIR:-$HOME/.local/bin}"

[ -d "$SRC" ] || { echo "No $SRC. Run scripts/build-app.sh first."; exit 1; }

# Quit a running copy so the bundle can be replaced.
osascript -e 'tell application id "dev.redact.app" to quit' >/dev/null 2>&1 || true
sleep 1

mkdir -p "$APP_DIR" "$BIN_DIR"
rm -rf "$APP_DIR/Redact.app"
cp -R "$SRC" "$APP_DIR/Redact.app"
ln -sf "$APP_DIR/Redact.app/Contents/Resources/bin/redact" "$BIN_DIR/redact"

echo "Installed $APP_DIR/Redact.app"
echo "Linked    $BIN_DIR/redact"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "Note: $BIN_DIR is not on your PATH. Add it to ~/.zshrc:  export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac
echo
echo "Connect Claude Code (optional):"
echo "  claude mcp add --scope user redact -- $BIN_DIR/redact mcp"
