#!/bin/zsh
# Archives Nimble Name and exports a Mac App Store package (.pkg) signed with
# "Apple Distribution" / "Mac Installer Distribution", ready for upload.
#
# Usage:
#   scripts/appstore.sh            # archive + export .pkg into dist/appstore/
#   scripts/appstore.sh --upload   # same, then upload to App Store Connect with the
#                                  # Apple ID signed in to Xcode (Settings → Accounts)
#
# Alternatives to --upload: open the .pkg with the Transporter app, or use
# Xcode → Window → Organizer → Distribute App on dist/appstore/Nimble Name.xcarchive.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$PROJECT_DIR/NimbleName.xcodeproj"
SCHEME="NimbleName"
APP_NAME="Nimble Name"
OUT="$PROJECT_DIR/dist/appstore"
ARCHIVE="$OUT/$APP_NAME.xcarchive"
EXPORT="$OUT/export"
OPTIONS="$PROJECT_DIR/scripts/ExportOptions-AppStore.plist"
UPLOAD=0
[[ "${1:-}" == "--upload" ]] && UPLOAD=1

rm -rf "$OUT"; mkdir -p "$OUT"

echo "▶ Archiving…"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -destination "generic/platform=macOS" -archivePath "$ARCHIVE" archive -quiet

if (( UPLOAD )); then
  echo "▶ Exporting and uploading to App Store Connect…"
  TMP_OPTIONS="$OUT/ExportOptions-upload.plist"
  cp "$OPTIONS" "$TMP_OPTIONS"
  /usr/libexec/PlistBuddy -c 'Set :destination upload' "$TMP_OPTIONS"
  xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$TMP_OPTIONS" -exportPath "$EXPORT" -allowProvisioningUpdates
  echo "✅ Uploaded. Finish the submission in App Store Connect."
else
  echo "▶ Exporting App Store package…"
  xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$OPTIONS" -exportPath "$EXPORT" -allowProvisioningUpdates -quiet
  echo "✅ Done: $(ls "$EXPORT"/*.pkg)"
  echo "   Upload it with the Transporter app, or rerun with --upload."
fi
