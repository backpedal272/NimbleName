#!/bin/zsh
# Builds, signs (Developer ID), notarizes, staples and packages Nimble Name as a DMG.
#
# One-time setup (interactive, needs your Apple ID and an app-specific password
# from https://account.apple.com → Sign-In and Security → App-Specific Passwords):
#   xcrun notarytool store-credentials NimbleName-notary --apple-id YOU@EXAMPLE.COM --team-id 5U2JDBY88V
#
# Usage:
#   scripts/release.sh            # full pipeline
#   scripts/release.sh --no-notarize   # archive + export + DMG only (for a local check)
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$PROJECT_DIR/NimbleName.xcodeproj"
SCHEME="NimbleName"
APP_NAME="Nimble Name"
PROFILE="NimbleName-notary"
OUT="$PROJECT_DIR/dist"
ARCHIVE="$OUT/$APP_NAME.xcarchive"
EXPORT="$OUT/export"
NOTARIZE=1
[[ "${1:-}" == "--no-notarize" ]] && NOTARIZE=0

VERSION=$(sed -n 's/.*MARKETING_VERSION = \([^;]*\);.*/\1/p' "$PROJECT/project.pbxproj" | head -1)
DMG="$OUT/NimbleName-$VERSION.dmg"

rm -rf "$OUT"; mkdir -p "$OUT"

echo "▶ Archiving…"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -destination "generic/platform=macOS" -archivePath "$ARCHIVE" archive -quiet

echo "▶ Exporting with Developer ID…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$PROJECT_DIR/scripts/ExportOptions.plist" \
  -exportPath "$EXPORT" -quiet

APP="$EXPORT/$APP_NAME.app"
codesign --verify --deep --strict "$APP"
echo "   signed by: $(codesign -dvv "$APP" 2>&1 | grep "^Authority=Developer ID Application" | cut -d= -f2)"

if (( NOTARIZE )); then
  echo "▶ Notarizing app (this takes a few minutes)…"
  ditto -c -k --keepParent "$APP" "$OUT/app.zip"
  xcrun notarytool submit "$OUT/app.zip" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$APP"
  rm "$OUT/app.zip"
fi

echo "▶ Building DMG…"
STAGE="$OUT/dmg-root"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read me first.txt" <<'TXT'
Nimble Name renames PDF and image files from their content using a local AI model.

It needs an OpenAI-compatible model server running on your Mac, for example oMLX
(https://omlx.ai) with a vision-capable model such as Qwen3.6-35B-A3B. Set the server
address and model name in Nimble Name → Settings → Model, then click Test Connection.

Drag the app to the Applications folder to install.
TXT
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"
# The disk image itself must carry a Developer ID signature for Gatekeeper to accept it.
codesign --sign "Developer ID Application" --timestamp "$DMG"

if (( NOTARIZE )); then
  echo "▶ Notarizing DMG…"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
  echo "▶ Gatekeeper check:"
  spctl -a -t open --context context:primary-signature -v "$DMG"
fi

echo "✅ Done: $DMG"
