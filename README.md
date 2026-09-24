# ToWatchDB

A movie and TV tracker for macOS, iOS and iPadOS, built with SwiftUI + SwiftData on top of TMDB.
One multiplatform target: a sidebar on Mac and iPad, five compact tabs on iPhone.

Organize with **spaces** (curated collections with an icon and color), **tags**, and **smart lists**
(saved filters by type, status, genre, rating, year, tags, spaces, backlog, favorites). Create them from
File ▸ New…, the Organize screen, or a title's "Spaces & Tags" menu; drop posters on a space or tag to file them.

**Stats** show watch time, movies, episodes, and shows for a week, month, 30/90 days, a year, or all time,
with monthly activity, top genres and actors, highlights, a comparison with another year, and a shareable
**Year in Review** card. (Mac/iPad: sidebar; iPhone: the Stats chip in the Library tab.)

**Where to Watch** on every title lists streaming, free, ad-supported, rent, and buy options for a country
(default: your device's region; change it per title or in Settings). Availability powered by JustWatch via TMDB.

**Backup** (Settings, or File ▸ Import/Export on Mac): export the whole library as JSON and import it on any
device. Importing merges, so nothing is lost or duplicated. **Export as CSV** gives one row per title for spreadsheets.

**Siri & Shortcuts**: 18 actions (next episodes, upcoming, mark watched, rate, notes, backlog, stats, where to
watch, open lists/collections/titles, search) and 9 ready-made Siri phrases such as "What's next in ToWatchDB"
or "Mark Severance watched in ToWatchDB". The system only runs them for apps signed with a team: add a free Apple ID
in Xcode ▸ Settings ▸ Accounts and set `DEVELOPMENT_TEAM` / `CODE_SIGN_IDENTITY` in `Config/Secrets.xcconfig`
(see `Secrets.example.xcconfig`).

On iPad and Mac, any title can open in its own window, posters drag into the library or backlog
(or out to other apps as a TMDB link), and the Title menu acts on the title on screen:
⇧⌘E mark watched / next episode, ⇧⌘B backlog, ⇧⌘L favorite, ⇧⌘R refresh.

## Setup

1. `brew install xcodegen`
2. `cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig` and paste your TMDB v4 read access token
   (the file is gitignored; a token can also be set at runtime in Settings, stored in the Keychain).
   Optionally add your signing team there too, so Siri & Shortcuts actions run.
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
