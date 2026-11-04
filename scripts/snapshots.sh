#!/bin/bash
# Screenshots of every section with real Liquid Glass: the app is launched normally
# (glass needs a LaunchServices launch) and this script, which needs screen recording
# permission for the terminal, captures each region when the app asks for it.
#
#   scripts/snapshots.sh <out-dir> [app] [extra app args…]
set -euo pipefail
OUT="${1:?out dir}"
APP="${2:-build/DerivedData/Build/Products/Release/SuckMyDisk.app}"
shift $(( $# >= 2 ? 2 : 1 ))
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
rm -f "$OUT"/*.png "$OUT"/*.region
open -n "$APP" --args --snapshot "$OUT" --snapshot-external "$@"
sleep 2
deadline=$((SECONDS + 240))
while pgrep -f "$APP/Contents/MacOS/SuckMyDisk" >/dev/null && [ $SECONDS -lt $deadline ]; do
  for r in "$OUT"/*.region; do
    [ -e "$r" ] || continue
    sleep 0.3
    screencapture -x -R"$(cat "$r")" "${r%.region}"
    rm -f "$r"
  done
  sleep 0.2
done
ls "$OUT"
