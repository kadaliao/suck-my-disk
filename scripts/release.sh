#!/bin/bash
# Build, sign, notarize and package a release into build/release/.
#
#   scripts/release.sh
#
# Notarizing takes one of:
#   - an App Store Connect API key: NOTARY_KEY (the .p8 file), NOTARY_KEY_ID and NOTARY_ISSUER.
#     Nothing is kept in a keychain, so nothing can go missing from one. When none of the
#     variables here is set they are read from ~/.appstoreconnect/notary.env, if it exists.
#   - a notarytool keychain profile: NOTARY_PROFILE, with NOTARY_KEYCHAIN naming the keychain
#     file it is in when that isn't the login keychain.
# With neither, the build is signed but not notarized. NOTARIZE=0 says so on purpose.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -nE 's/^ *MARKETING_VERSION: "?([^"]+)"?$/\1/p' project.yml)
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Xingyi Liao (HMDAVG9B8J)}"
NOTARY_ENV="$HOME/.appstoreconnect/notary.env"
if [ -z "${NOTARY_PROFILE:-}${NOTARY_KEY:-}" ] && [ "${NOTARIZE:-1}" != 0 ] && [ -r "$NOTARY_ENV" ]; then
  # shellcheck disable=SC1090
  . "$NOTARY_ENV"
fi
NOTARY=()
if [ "${NOTARIZE:-1}" = 0 ]; then
  :
elif [ -n "${NOTARY_KEY:-}" ]; then
  : "${NOTARY_KEY_ID:?NOTARY_KEY needs NOTARY_KEY_ID}" "${NOTARY_ISSUER:?NOTARY_KEY needs NOTARY_ISSUER}"
  [ -r "$NOTARY_KEY" ] || { echo "can't read NOTARY_KEY: $NOTARY_KEY" >&2; exit 1; }
  NOTARY=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
elif [ -n "${NOTARY_PROFILE:-}" ]; then
  NOTARY=(--keychain-profile "$NOTARY_PROFILE")
  if [ -n "${NOTARY_KEYCHAIN:-}" ]; then NOTARY+=(--keychain "$NOTARY_KEYCHAIN"); fi
fi
if [ ${#NOTARY[@]} -gt 0 ]; then
  # Before the build, not twenty minutes into it: the credentials must work now.
  xcrun notarytool history "${NOTARY[@]}" >/dev/null || { echo "notarytool can't sign in with these credentials" >&2; exit 1; }
else
  echo "▸ not notarizing: don't publish this build"
fi
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

if [ ${#NOTARY[@]} -gt 0 ]; then
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
if [ ${#NOTARY[@]} -gt 0 ]; then
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
