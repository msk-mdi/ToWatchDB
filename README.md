# ToWatchDB

A movie and TV tracker for macOS (iOS and iPadOS next), built with SwiftUI + SwiftData on top of TMDB.

## Setup

1. `brew install xcodegen`
2. `cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig` and paste your TMDB v4 read access token
   (the file is gitignored; a token can also be set at runtime in Settings, stored in the Keychain).
3. `xcodegen generate && open ToWatchDB.xcodeproj`

The Xcode project is generated from `project.yml` — edit that, not the `.xcodeproj`.

## Layout

- `Packages/ToWatchCore` — TMDB client, SwiftData models, library/watch-state/upcoming logic. Tested with `swift test`.
- `ToWatchDB/` — SwiftUI app (sidebar-adaptable tabs, detail views, settings).

## Checks

```bash
cd Packages/ToWatchCore && swift test
xcodebuild -project ToWatchDB.xcodeproj -scheme ToWatchDB -destination 'platform=macOS' test
# Debug visual pass: seeds sample titles into an in-memory store and writes a PNG per screen
ToWatchDB.app/Contents/MacOS/ToWatchDB -UISnapshotDir ~/Library/Containers/com.mehdi.towatchdb/Data/tmp/snap
```

This product uses the TMDB API but is not endorsed or certified by TMDB.
