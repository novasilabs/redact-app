#!/bin/zsh
# Renders every main screen with demo data (no real secrets) into docs/screenshots/{light,dark}.
#   scripts/snapshots.sh            both appearances
#   scripts/snapshots.sh dark       one appearance
# Uses a throwaway vault in $TMPDIR (short path, so the agent socket fits) and the DevSnapshot mode
# of the app (REDACT_HOME + REDACT_SNAPSHOT_DIR). The installed app and your real vault are untouched.
set -eu
cd "$(dirname "$0")/.."

swift build >/dev/null
./scripts/build-app.sh debug >/dev/null 2>&1   # dev hooks exist only in debug builds

work=$(mktemp -d -t redact-snap)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/home" "$work/code/acme/workers/billing"
REDACT_HOME="$work/home" .build/debug/redact-devtool make-vault --sample "$work/code/acme" >/dev/null

appearances=("$@"); (( $#appearances )) || appearances=(light dark)
for appearance in $appearances; do
  out="docs/screenshots/$appearance"
  rm -rf "$out"; mkdir -p "$out"
  REDACT_SNAPSHOT_APPEARANCE=$appearance REDACT_HOME="$work/home" REDACT_SNAPSHOT_DIR="$PWD/$out" \
    REDACT_SNAPSHOT_SIZE="${REDACT_SNAPSHOT_SIZE:-1200x760}" \
    REDACT_SNAPSHOT_PATH_ALIAS="$(cd "$work/code" && pwd -P)=~/code" \
    build/Redact.app/Contents/MacOS/Redact >/dev/null 2>&1
  rm -f "$out"/*.redact   # the demo backup the restore step writes
  echo "$out: $(ls "$out" | wc -l | tr -d ' ') screens"
done
