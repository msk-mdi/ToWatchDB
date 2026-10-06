#!/bin/zsh
# Builds an unsigned Release .ipa for iPhone and iPad into dist/ToWatchDB.ipa.
#
# Unsigned, so it can't be installed as is: a sideloading tool (AltStore, Sideloadly) signs it with your
# free Apple ID while installing. Free-account installs expire after 7 days; those tools renew them.
# Release builds carry no TMDB token; paste yours in Settings.
set -euo pipefail
cd "${0:A:h}/.."

xcodegen generate --quiet
xcodebuild -project ToWatchDB.xcodeproj -scheme ToWatchDB -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build/Release-ipa \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build | grep -E 'error:|BUILD' || true

app=build/Release-ipa/Build/Products/Release-iphoneos/ToWatchDB.app
[[ -d $app ]] || { echo "Build failed"; exit 1; }
staging=$(mktemp -d)
mkdir "$staging/Payload"
ditto "$app" "$staging/Payload/ToWatchDB.app"
mkdir -p dist
rm -f dist/ToWatchDB.ipa
(cd "$staging" && zip -qry "$OLDPWD/dist/ToWatchDB.ipa" Payload)
rm -rf "$staging"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Info.plist")
echo "Built ToWatchDB $version (iPhone + iPad): dist/ToWatchDB.ipa ($(du -h dist/ToWatchDB.ipa | cut -f1), unsigned)"
