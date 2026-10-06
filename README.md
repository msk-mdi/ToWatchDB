# ToWatchDB

A movie and TV tracker for macOS, iOS and iPadOS, built with SwiftUI + SwiftData on top of TMDB.
One multiplatform target: on Mac and iPad, a permanent sidebar or a top tab bar (chosen in Settings); five compact tabs on iPhone.
Settings also picks the accent color and the app icon color (iOS alternate icons; on macOS, the Dock icon while the app runs).

Organize with **spaces** (curated collections with an icon and color), **tags**, and **smart lists**
(saved filters by type, status, genre, rating, year, tags, spaces, backlog, favorites). Create them from
File ▸ New…, the Organize screen, or a title's "Spaces & Tags" menu; drop posters on a space or tag to file them.

**Stats** show watch time, movies, episodes, and shows for a week, month, 30/90 days, a year, or all time,
with monthly activity, top genres and actors, highlights, a comparison with another year, and a shareable
**Year in Review** card. (Sidebar layout: its own entry; Mac top bar: a tab; iPhone and iPad top bar: the Stats chip in the Library tab.)

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
   Only Debug builds use it: Release builds ship without a token.
   Optionally add your signing team there too, so Siri & Shortcuts actions run.
3. `xcodegen generate && open ToWatchDB.xcodeproj`

The Xcode project is generated from `project.yml` — edit that, not the `.xcodeproj`.

## Release builds

No paid Apple Developer account needed; these are for your own devices. Release builds have no built-in
TMDB token: on first launch, paste your API Read Access Token (themoviedb.org ▸ Settings ▸ API) in Settings.

- **Mac:** `Scripts/build-mac.sh` builds `dist/ToWatchDB.app` (and a zip); drag it into Applications. It's signed
  ad hoc, so it runs on the Mac that built it; on another Mac, right-click ▸ Open the first time.
- **iPhone / iPad:** add a free Apple ID in Xcode ▸ Settings ▸ Accounts, put its team ID in
  `Config/Secrets.xcconfig` (`DEVELOPMENT_TEAM = …`), connect the device (Developer Mode on), and run
  `Scripts/install-ios.sh`. Free-account installs expire after 7 days; run the script again to renew.
  Your library is kept.

- **`.ipa` (iPhone + iPad):** `Scripts/build-ipa.sh` builds an unsigned `dist/ToWatchDB.ipa`. Install it with a
  sideloading tool such as AltStore or Sideloadly, which signs it with your free Apple ID (renewed every 7 days).

The version is `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml`.

## Layout

- `Packages/ToWatchCore` — TMDB client, SwiftData models, library/watch-state/upcoming logic. Tested with `swift test`.
- `ToWatchDB/` — SwiftUI app (sidebar or tab bar layouts, detail views, settings).
- `Scripts/generate-icons.swift` — redraws the themed app icons and their Settings previews.
- `Scripts/snapshot-mac.sh` — debug visual pass: captures each screen's window on macOS.

**[docs/CODEBASE.md](docs/CODEBASE.md)** explains the whole codebase: architecture, data model, every screen,
navigation and layouts, performance choices, rules to follow, debugging tools, and how-tos.

## Checks

```bash
cd Packages/ToWatchCore && swift test
xcodebuild -project ToWatchDB.xcodeproj -scheme ToWatchDB -destination 'platform=macOS' test
xcodebuild -project ToWatchDB.xcodeproj -scheme ToWatchDB -destination 'platform=iOS Simulator,name=iPhone 17' build
# Debug builds: seed sample titles into a throwaway in-memory store (any platform)
xcrun simctl launch booted com.mehdi.towatchdb -UISeedSampleData YES
# macOS: visit each screen and capture its window (needs Screen Recording permission for the terminal)
Scripts/snapshot-mac.sh -navigationLayout sidebar
```

This product uses the TMDB API but is not endorsed or certified by TMDB.
