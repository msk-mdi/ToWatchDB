# ToWatchDB

A movie and TV tracker for macOS, iOS and iPadOS, built with SwiftUI + SwiftData on top of TMDB.
One multiplatform target: a sidebar on Mac and iPad, five compact tabs on iPhone.

On iPad and Mac, any title can open in its own window, posters drag into the library or backlog
(or out to other apps as a TMDB link), and the Title menu acts on the title on screen:
⇧⌘E mark watched / next episode, ⇧⌘B backlog, ⇧⌘L favorite, ⇧⌘R refresh.

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
xcodebuild -project ToWatchDB.xcodeproj -scheme ToWatchDB -destination 'platform=iOS Simulator,name=iPhone 17' build
# Debug builds: seed sample titles into a throwaway in-memory store (any platform)
xcrun simctl launch booted com.mehdi.towatchdb -UISeedSampleData YES
# macOS: also visit each screen, write a PNG per screen, and quit
ToWatchDB.app/Contents/MacOS/ToWatchDB -UISnapshotDir ~/Library/Containers/com.mehdi.towatchdb/Data/tmp/snap
```

This product uses the TMDB API but is not endorsed or certified by TMDB.
