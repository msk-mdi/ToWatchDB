#!/bin/zsh
# Builds a Release copy of ToWatchDB and installs it on a connected iPhone or iPad.
#
# Needs a free Apple ID (no paid program) — once:
#   1. Xcode ▸ Settings ▸ Accounts ▸ + ▸ Apple ID.
#   2. Put its team ID in Config/Secrets.xcconfig:  DEVELOPMENT_TEAM = ABCDE12345
#      (Xcode ▸ Settings ▸ Accounts ▸ your account shows the "Personal Team"; or run this script, which lists it.)
#   3. Connect the device with a cable and turn on Developer Mode (Settings ▸ Privacy & Security).
#   4. After the first install, trust the developer on the device: Settings ▸ General ▸ VPN & Device Management.
#
# Free-account apps stop opening after 7 days: run this script again to renew. Your library stays.
# Release builds carry no TMDB token; paste yours in Settings.
set -euo pipefail
cd "${0:A:h}/.."

team=$(sed -n 's/^ *DEVELOPMENT_TEAM *= *\([A-Z0-9]*\).*/\1/p' Config/Secrets.xcconfig 2>/dev/null | tail -1)
if [[ -z $team ]]; then
  echo "No DEVELOPMENT_TEAM in Config/Secrets.xcconfig. Teams Xcode knows about:"
  defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null | grep -E 'teamID|teamName' || echo "  (none: add your Apple ID in Xcode ▸ Settings ▸ Accounts)"
  exit 1
fi

device=$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /available|connected/ && !/unavailable/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) { print $i; exit } }')
[[ -n $device ]] || { echo "No connected iPhone or iPad found (xcrun devicectl list devices)."; exit 1; }

xcodegen generate --quiet
xcodebuild -project ToWatchDB.xcodeproj -scheme ToWatchDB -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build/Release-ios \
  -allowProvisioningUpdates DEVELOPMENT_TEAM="$team" CODE_SIGN_IDENTITY="Apple Development" \
  build | grep -E 'error:|BUILD' || true

app=build/Release-ios/Build/Products/Release-iphoneos/ToWatchDB.app
[[ -d $app ]] || { echo "Build failed"; exit 1; }
xcrun devicectl device install app --device "$device" "$app"
echo "Installed on $device. First time: trust the developer in Settings ▸ General ▸ VPN & Device Management."
