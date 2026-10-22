#!/bin/zsh
# Builds a Release copy of ToWatchDB for this Mac into dist/ToWatchDB.app (and a zip of it).
#
# Without a paid Apple Developer account the app is signed ad hoc: it runs on the Mac that built it.
# Copied to another Mac, Gatekeeper blocks it until you right-click ▸ Open (or allow it in
# System Settings ▸ Privacy & Security). Release builds carry no TMDB token; paste yours in Settings.
set -euo pipefail
cd "${0:A:h}/.."

xcodegen generate --quiet
app=build/Release-mac/Build/Products/Release/ToWatchDB.app
# Removed first: a failed build would otherwise leave the previous build's app, and it was packaged as if new.
rm -rf "$app"
xcodebuild -project ToWatchDB.xcodeproj -scheme ToWatchDB -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build/Release-mac \
  build | grep -E 'error:|warning:|BUILD' || true
# The grep's status is the pipeline's; xcodebuild's is what matters.
(( pipestatus[1] == 0 )) && [[ -d $app ]] || { echo "Build failed"; exit 1; }
rm -rf dist/ToWatchDB.app dist/ToWatchDB-mac.zip
mkdir -p dist
ditto "$app" dist/ToWatchDB.app
ditto -c -k --keepParent dist/ToWatchDB.app dist/ToWatchDB-mac.zip
version=$(defaults read "$PWD/dist/ToWatchDB.app/Contents/Info.plist" CFBundleShortVersionString)
echo "Built ToWatchDB $version: dist/ToWatchDB.app (zip: dist/ToWatchDB-mac.zip)"
echo "Install: drag dist/ToWatchDB.app into /Applications."
