#!/bin/zsh
# Builds a signed, notarized disk image to share Macarum with other Macs:
# build/Macarum-<version>.dmg holds Macarum.app and a link to /Applications to drag it onto.
# This is the file the website and the Homebrew cask download (docs/guides/sharing.md).
# Needs a "Developer ID Application" certificate in the login keychain and an App Store
# Connect API key for notarization, given in the environment: NOTARY_KEY_ID, NOTARY_ISSUER
# and NOTARY_KEY (the path of the .p8 file).
set -euo pipefail
cd "$(dirname "$0")/.."

: "${NOTARY_KEY_ID:?Set NOTARY_KEY_ID}" "${NOTARY_ISSUER:?Set NOTARY_ISSUER}" "${NOTARY_KEY:?Set NOTARY_KEY}"

APP_ID="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
[[ -n "$APP_ID" ]] || { echo "Missing the Developer ID Application certificate" >&2; exit 1; }

MACARUM_SIGN_IDENTITY="$APP_ID" tools/build_app.sh --bundle
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' build/Macarum.app/Contents/Info.plist)"
DMG="build/Macarum-$VERSION.dmg"
NOTARY=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait)

# The app gets its own ticket so it opens offline once Homebrew has copied it out of the image.
ditto -c -k --keepParent build/Macarum.app build/Macarum-notarize.zip
xcrun notarytool submit build/Macarum-notarize.zip "${NOTARY[@]}"
rm build/Macarum-notarize.zip
xcrun stapler staple build/Macarum.app

# The image shows the app next to an Applications link, the usual drag-to-install window.
rm -rf build/dmgroot "$DMG"
mkdir -p build/dmgroot
ditto --noextattr --noqtn build/Macarum.app build/dmgroot/Macarum.app
ln -s /Applications build/dmgroot/Applications
hdiutil create -quiet -volname "Macarum" -srcfolder build/dmgroot -fs APFS -format ULFO "$DMG"
rm -rf build/dmgroot

codesign --sign "$APP_ID" --timestamp "$DMG"
xcrun notarytool submit "$DMG" "${NOTARY[@]}"
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"
echo "SHA-256 $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "Ready to share: $PWD/$DMG"
