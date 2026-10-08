# ToWatchDB: development

Building and working on ToWatchDB. For what the app does and how to install it, see the [README](../README.md).

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
device. Importing merges, so nothing is lost or duplicated. **Export as CSV** gives one row per title for
spreadsheets (it opens correctly in Excel, accented titles included).

**Dropbox Sync** (Settings ▸ Dropbox Sync): connect a Dropbox account and every device connected to it keeps
the same library, backlog, watch history, ratings, notes, and collections. Changes sync when the app opens and a
few seconds after each edit; removals and un-watching sync too. When nothing changed, a sync is one small request,
and a locked iPhone waits and tries again rather than disconnecting. Needs a Dropbox app key (see Setup).

**Seerr requests** (Settings ▸ Seerr): sign in to a Seerr, Overseerr, or Jellyseerr server with a Jellyfin or
Emby account, a Seerr account, or the server's API key. Every title page can then **Request on Seerr** (pick the
seasons of a show), shows when it's requested, offers **Watch Now** once it's on your media server, and can
delete a request. An address without `http://` uses http on the home network and https otherwise.

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
   (the file is gitignored; a token can also be set at runtime in Settings, stored in the Keychain on iPhone and iPad, and in a file encrypted by the Secure Enclave on Mac).
   The Dropbox and Seerr sign-ins are stored the same way.
   Only Debug builds use it: Release builds ship without a token.
   Optionally add your signing team there too, so Siri & Shortcuts actions run.
   For Dropbox Sync, create an app at <https://www.dropbox.com/developers/apps> (Scoped access, **App folder**,
   named e.g. ToWatchDB), enable the `files.content.read` and `files.content.write` permissions, and put its
   app key in `DROPBOX_APP_KEY`. The key isn't secret (sign-in uses PKCE), so Release builds keep it. A new
   Dropbox app only accepts your own account: click **Enable additional users** on its App Console page to let
   up to 500 accounts connect (the released app has this on). Once 50 accounts have connected, Dropbox gives two
   weeks to apply for production status (**Apply for production**, free) before new accounts are blocked.
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

The version is `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml` (currently 1.4.0, build 10).
Releases are on the [GitHub releases page](https://github.com/msk-mdi/ToWatchDB/releases): `ToWatchDB.app.zip`
for Mac and `ToWatchDB.ipa` for iPhone and iPad.

## Layout

- `Packages/ToWatchCore` — TMDB, IMDb and Seerr clients, SwiftData models, library/watch-state/upcoming logic,
  backup and sync merging. Tested with `swift test`.
- `ToWatchDB/` — SwiftUI app (sidebar or tab bar layouts, detail views, settings, Dropbox sync, Siri actions).
- `Scripts/generate-icons.swift` — redraws the themed app icons and their Settings previews.
- `Scripts/snapshot-mac.sh` — debug visual pass: captures each screen's window on macOS.

**[CODEBASE.md](CODEBASE.md)** explains the whole codebase: architecture, data model, every screen,
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
