#!/bin/bash
# Build, sign, notarize and package a release into build/release/.
#
#   NOTARY_PROFILE=<notarytool keychain profile> scripts/release.sh
#
# Without NOTARY_PROFILE the build is signed but not notarized.
# NOTARY_KEYCHAIN names the keychain file the profile is in, when it isn't the login keychain
# (over SSH the login keychain can't take a new profile, so the profile lives in its own file).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -nE 's/^ *MARKETING_VERSION: "?([^"]+)"?$/\1/p' project.yml)
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Xingyi Liao (HMDAVG9B8J)}"
NOTARY=(--keychain-profile "${NOTARY_PROFILE:-}")
if [ -n "${NOTARY_KEYCHAIN:-}" ]; then NOTARY+=(--keychain "$NOTARY_KEYCHAIN"); fi
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
# Installs come from GitHub: leave no runnable copy of the app in the build folder.
rm -rf build/DerivedData/Build/Products/Release/SuckMyDisk.app

echo "▸ smd"
SWIFT_ARGS=(--package-path Packages/DiskCore -c release --arch arm64 --arch x86_64)
swift build "${SWIFT_ARGS[@]}" --product smd
cp "$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)/smd" "$STAGE/smd"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$STAGE/smd"

codesign --verify --deep --strict "$STAGE/SuckMyDisk.app"
# The app only talks to a helper with this identifier and team, and the helper only to the app:
# a build where they don't match would fall back to Finder's password dialog without a word.
TEAM=$(codesign -dv "$STAGE/SuckMyDisk.app" 2>&1 | sed -nE 's/^TeamIdentifier=//p')
HELPER="$STAGE/SuckMyDisk.app/Contents/MacOS/com.kadaliao.SuckMyDisk.helper"
codesign --verify --strict -R="identifier \"com.kadaliao.SuckMyDisk.helper\" and anchor apple generic and certificate leaf[subject.OU] = \"$TEAM\"" "$HELPER"
codesign --verify --strict -R="identifier \"com.kadaliao.SuckMyDisk\" and anchor apple generic and certificate leaf[subject.OU] = \"$TEAM\"" "$STAGE/SuckMyDisk.app"
plutil -lint -s "$STAGE/SuckMyDisk.app/Contents/Library/LaunchDaemons/com.kadaliao.SuckMyDisk.helper.plist"
codesign --verify --strict "$STAGE/smd"

if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "▸ notarize"
  ditto -c -k "$STAGE" "$OUT/notarize.zip"
  xcrun notarytool submit "$OUT/notarize.zip" "${NOTARY[@]}" --wait
  xcrun stapler staple "$STAGE/SuckMyDisk.app"
  spctl --assess --type execute "$STAGE/SuckMyDisk.app"
  rm "$OUT/notarize.zip"
fi

# The disk image people download: the app next to a link to /Applications.
echo "▸ dmg"
DMG="$OUT/SuckMyDisk-$VERSION.dmg"
mkdir -p "$OUT/dmg"
ditto "$STAGE/SuckMyDisk.app" "$OUT/dmg/SuckMyDisk.app"
ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -quiet -volname "SuckMyDisk $VERSION" -srcfolder "$OUT/dmg" -fs APFS -format ULFO -ov "$DMG"
rm -rf "$OUT/dmg"
codesign --sign "$IDENTITY" --timestamp "$DMG"
if [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$DMG" "${NOTARY[@]}" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature "$DMG"
fi

ditto -c -k --keepParent "$STAGE/SuckMyDisk.app" "$OUT/SuckMyDisk-$VERSION.zip"
ditto -c -k "$STAGE/smd" "$OUT/smd-$VERSION-macos.zip"
# Only the archives stay: a loose copy of the app here would show up in Spotlight and Open With.
rm -rf "$STAGE"
(cd "$OUT" && shasum -a 256 ./*.dmg ./*.zip | sed 's| \./| |' > SHA256SUMS)
echo "▸ done"
ls -lh "$OUT"
