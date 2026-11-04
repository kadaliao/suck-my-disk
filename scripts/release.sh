#!/bin/bash
# Build, sign, notarize and package a release into build/release/.
#
#   NOTARY_PROFILE=<notarytool keychain profile> scripts/release.sh
#
# Without NOTARY_PROFILE the build is signed but not notarized.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -nE 's/^ *MARKETING_VERSION: "?([^"]+)"?$/\1/p' project.yml)
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Xingyi Liao (HMDAVG9B8J)}"
OUT=build/release
STAGE="$OUT/stage"
rm -rf "$OUT"
mkdir -p "$STAGE"

echo "▸ SuckMyDisk $VERSION"
xcodegen generate --quiet
xcodebuild -project SuckMyDisk.xcodeproj -scheme SuckMyDisk -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY="$IDENTITY" OTHER_CODE_SIGN_FLAGS="--timestamp" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  build -quiet
ditto build/DerivedData/Build/Products/Release/SuckMyDisk.app "$STAGE/SuckMyDisk.app"

echo "▸ smd"
SWIFT_ARGS=(--package-path Packages/DiskCore -c release --arch arm64 --arch x86_64)
swift build "${SWIFT_ARGS[@]}" --product smd
cp "$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)/smd" "$STAGE/smd"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$STAGE/smd"

codesign --verify --deep --strict "$STAGE/SuckMyDisk.app"
codesign --verify --strict "$STAGE/smd"

if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "▸ notarize"
  ditto -c -k "$STAGE" "$OUT/notarize.zip"
  xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$STAGE/SuckMyDisk.app"
  spctl --assess --type execute "$STAGE/SuckMyDisk.app"
  rm "$OUT/notarize.zip"
fi

ditto -c -k --keepParent "$STAGE/SuckMyDisk.app" "$OUT/SuckMyDisk-$VERSION.zip"
ditto -c -k "$STAGE/smd" "$OUT/smd-$VERSION-macos.zip"
(cd "$OUT" && shasum -a 256 ./*.zip | sed 's| \./| |' > SHA256SUMS)
echo "▸ done"
ls -lh "$OUT"
