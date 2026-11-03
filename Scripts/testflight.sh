#!/usr/bin/env bash
#
# testflight.sh — archive the iOS app with the TestFlight configuration and
# export it for App Store Connect, optionally uploading it.
#
# Usage:
#   Scripts/testflight.sh [--carplay] [--upload] [--version X.Y.Z] [--build N]
#
#   --carplay   include the CarPlay entitlement and scene (needs the approved
#               carplay-audio capability on the App ID; signing fails otherwise)
#   --upload    upload to App Store Connect instead of leaving the IPA on disk
#   --version   marketing version (default: the latest v* tag, without the v)
#   --build     build number (default: commit count, as the release workflow)
#
# Environment:
#   KUMONE_TEAM_ID   Apple Developer team ID (required unless
#                    ios/Config/TestFlight.local.xcconfig sets DEVELOPMENT_TEAM)
#   ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH
#                    App Store Connect API key, used for automatic provisioning
#                    and for --upload. Without it Xcode's signed-in account is used.
#
# Output lands in .build/testflight/: Kumone.xcarchive and, unless uploading,
# export/KumoneIOS.ipa for Transporter or the Organizer.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CARPLAY=0
UPLOAD=0
VERSION=""
BUILD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --carplay) CARPLAY=1 ;;
    --upload) UPLOAD=1 ;;
    --version) VERSION="$2"; shift ;;
    --build) BUILD="$2"; shift ;;
    -h|--help) sed -n '2,25p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; exit 2 ;;
  esac
  shift
done

if [ -z "$VERSION" ]; then
  VERSION="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null | sed 's/^v//')"
  [ -n "$VERSION" ] || { echo "error: no v* tag found; pass --version" >&2; exit 2; }
fi
[ -n "$BUILD" ] || BUILD="$(git rev-list --count HEAD)"

TEAM_ID="${KUMONE_TEAM_ID:-}"
if [ -z "$TEAM_ID" ] && [ -f ios/Config/TestFlight.local.xcconfig ]; then
  TEAM_ID="$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*//p' ios/Config/TestFlight.local.xcconfig | tail -1)"
fi
[ -n "$TEAM_ID" ] || { echo "error: set KUMONE_TEAM_ID or DEVELOPMENT_TEAM in ios/Config/TestFlight.local.xcconfig" >&2; exit 2; }

AUTH=()
if [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ] && [ -n "${ASC_KEY_PATH:-}" ]; then
  AUTH=(-authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID" -authenticationKeyPath "$ASC_KEY_PATH")
elif [ "$UPLOAD" -eq 1 ]; then
  echo "note: no App Store Connect API key in the environment; the upload will use Xcode's signed-in account" >&2
fi

OUT=".build/testflight"
ARCHIVE="$OUT/Kumone.xcarchive"
EXPORT="$OUT/export"
rm -rf "$OUT"; mkdir -p "$OUT"

if [ "$CARPLAY" -eq 1 ]; then
  Scripts/configure-ios.sh --carplay
else
  Scripts/configure-ios.sh
fi

echo "==> Archiving Kumone iOS $VERSION ($BUILD), TestFlight configuration, team $TEAM_ID, CarPlay $([ "$CARPLAY" -eq 1 ] && echo on || echo off)"
xcodebuild archive \
  -workspace ios/KumoneIOS.xcworkspace -scheme KumoneIOS \
  -configuration TestFlight -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates "${AUTH[@]}" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  | tail -20

DESTINATION=export
[ "$UPLOAD" -eq 1 ] && DESTINATION=upload
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$DESTINATION</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST

echo "==> Exporting ($DESTINATION)"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$EXPORT" \
  -allowProvisioningUpdates "${AUTH[@]}" \
  | tail -20

if [ "$UPLOAD" -eq 1 ]; then
  echo "✅ Uploaded Kumone iOS $VERSION ($BUILD) to App Store Connect; it appears in TestFlight after processing."
else
  echo "✅ Archive: $ARCHIVE"
  echo "✅ IPA:     $EXPORT/KumoneIOS.ipa  (upload with Transporter, or rerun with --upload)"
fi
