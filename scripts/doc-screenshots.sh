#!/bin/bash
# Regenerates the screenshots in docs/images (English and Chinese) from demo mode,
# so they show made-up projects instead of your own. Build the Release app first, and
# run this from a terminal that has Screen Recording permission.
#
#   scripts/doc-screenshots.sh [app]
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-build/DerivedData/Build/Products/Release/SuckMyDisk.app}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# snapshots.sh file name → docs/images file name
NAMES="0-overview:overview 1-project:projects 2-media:media 3-devCache:dev-caches 4-model:models
       5-appData:app-data 6-disk:whole-disk 7-timeline:timeline 9-clean-sheet:clean-up"

for lang in en zh-CN; do
  if [ "$lang" = zh-CN ]; then apple="(zh-Hans)"; else apple="(en)"; fi
  scripts/snapshots.sh "$TMP/$lang" "$APP" --demo -AppleLanguages "$apple" \
    --snapshot-size 1440x900 --snapshot-appearance light
  mkdir -p "docs/images/$lang"
  for n in $NAMES; do
    sips -Z 1600 "$TMP/$lang/${n%%:*}.png" --out "docs/images/$lang/${n##*:}.png" >/dev/null
  done
done
ls -l docs/images/en docs/images/zh-CN
