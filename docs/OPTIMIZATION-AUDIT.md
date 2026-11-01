# ToWatchDB: optimization audit

Audited: version 2.1.2, commit `7f7f0d6`, on 2026-11-01. This is a static review of the whole app target and
the `ToWatchCore` package, read against [CODEBASE.md](CODEBASE.md) §7 and §8. It leaves out everything in
[IOS-AUDIT.md](IOS-AUDIT.md), including its open finding 10 (no `#Index`). Costs come from the timings in
CODEBASE §7; nothing was profiled for this audit. Each finding is marked either **confirmed** (checked against
the code) or **plausible** (the code reads that way, but nothing was measured).

## Summary

The codebase is already well tuned. Most hot paths use dictionaries, batch their saves, and do heavy work off
the main thread. What remains falls into four groups:

1. **Paths that missed the earlier fixes.** Two Siri intents and the Shortcuts entity picker still go through
   every episode on the main thread.
2. **Dropbox sync costs.** Syncs do whole-library work that is then thrown away.
3. **Per-row relationship faults.** Smart lists and poster menus load each title's relationships one by one.
4. **Over-broad SwiftUI dependencies.** Some views redraw on saves they don't need to.

## High

| # | Finding | Where | Fix |
|---|---|---|---|
| 1 | **Fixed.** **"Get Next Episodes" goes through every show's episodes on the main thread.** It runs `progressSummary()` once per show in `mainContext`; §7 item 18 puts this at about 3.4 s for 300 shows. A Siri launch starts with a fresh context and no warm-up, so it pays the worst case. Confirmed. | `Intents.swift:30-35`, `SpokenSummaries.swift:5-14` | Pass `nextEpisodes` a progress map: `AppState.shared?.showProgressIfReady()`, or else `TVShow.progressSummaries(in:)` in a detached context, as `ShowQuery.suggestedEntities` already does. |
| 2 | **A TMDB refresh triggers a whole-library sync pass that uploads nothing.** `apply` always sets `lastRefreshed`, so the save moves the version past `syncedVersion`. The sync then takes a full `makeBackup` (about 2 s for 300 shows), encodes and compresses it, and rewrites the base file. Then `sameContent` finds nothing to upload, because TMDB data is excluded from it. Confirmed. | `DropboxSync.swift:233-311`, `LibraryService.swift:585,613`, `AppState.swift:202-205` | When a save contains only refresh metadata and nothing was unsynced before it, move `syncedVersion` forward instead of running a sync. |
| 3 | **Fixed.** **Smart lists load every title's `tags` and `spaces`.** They are passed as ordinary arguments, so both are read even when the rule has no tag or space criteria. With 1,300 titles that is up to 2,600 to-many faults on the main thread, after every save while the list is visible. Confirmed. | `Collections.swift:107-119`, `LibraryView.swift:389-399` | Make them `@autoclosure`, or resolve the rule's few spaces and tags once into a set of IDs. |

## Medium

| # | Finding | Where | Fix |
|---|---|---|---|
| 4 | **Fixed.** **"Get Watch Stats" computes stats on the main context.** §7 item 4 puts this at about 0.45 s for 300 shows. Confirmed. | `Intents.swift:65-70` | Use `Task.detached` with a new `ModelContext`. `WatchStats` is already `Sendable`. |
| 5 | **Each merge pass encodes or decodes the whole library about 5 extra times.** `normalized` round-trips base, local and remote (base and remote are already normalized). `changes()` encodes titles only to compare them. `loadBase` re-reads and decodes the base file on every pass, and up to 5 passes can run. This also roughly doubles peak memory. Confirmed. | `LibrarySync.swift:20,111,211-220`, `DropboxSync.swift:258-261` | Normalize `local` only, compare with `Equatable`, and decode the base once, outside the pass loop. |
| 6 | **The library is snapshotted again after applying a merge.** That is a second `makeBackup` (about 2 s for 300 shows) on every sync that brings in another device's changes. Plausible. | `DropboxSync.swift:285-287` | Upload `merged` directly. Back this with a test that `sameContent(merged, makeBackup())` holds after an apply. |
| 7 | **The Stats page loads every watched episode up to 3 times after each save.** It runs `stats(period)`, `watchYears`, and the comparison year, each in its own context. Confirmed. | `StatsService.swift:112-124,197-205`, `StatsView.swift:73-78,428-431` | Add one call that fetches once and computes every period plus the year list. |
| 8 | **The Siri shortcut hash goes through every episode again on nearly every activation.** It is keyed on `libraryVersion`, so the previous refresh or sync saves invalidate it. Nothing tracks a computation that is already running, so iPad multi-window can run two at once. Confirmed; the duplicate run is plausible. | `ToWatchDBApp.swift:53-61`, `AppState.swift:341-371` | Hash from `showProgressIfReady()` when it is ready, and keep the in-flight `Task` so concurrent callers await it. |
| 9 | **Fixed.** **A cached poster goes blank if `NSCache` evicts it.** On a cache hit, `loaded` stays nil and the body reads the cache on every redraw. After an eviction (on iOS, memory pressure), the placeholder shows and `.task(id: url)` does not run again. Confirmed. | `RemoteImage.swift:114,130-133` | On a hit, set `loaded = cachedImage` (it is a reference, so this costs nothing). |
| 10 | **Fixed.** **Seerr is asked for a title's status again on every page switch, including when the page is being hidden.** `isActive` is part of the task id, and the fetch runs before `isActive` is checked. Confirmed. | `SeerrRequestButton.swift:40,135-163` | Return early when the page is inactive, and refetch on activation only if the status is stale or still in progress. |
| 11 | **Fixed.** **Poster context menus load each card's `spaces` and `tags`.** On macOS, every visible card's menu is built up front. Confirmed. | `CollectionViews.swift:17-18` | Build a membership map once in the grid's `cached` closure and pass it to each card. |
| 12 | **Fixed.** **Every save redraws every open show page, including hidden ones.** The `cached("episodes-with-notes")` read in the body ties the whole page to `libraryVersion`, so each save re-runs `progressSummary()` and the season and episode sorts. `onAppear` also goes through the episodes again. Confirmed. | `TVShowDetailView.swift:31-32,97-99,174-177` | Move the episode list into a child view, and reuse `progress.nextEpisode` in `onAppear`. |

## Low

| # | Finding | Where | Fix |
|---|---|---|---|
| 13 | **Fixed.** Shortcuts entity queries call `nextEpisodeToWatch()` for each matching show on the main thread. Confirmed. | `Entities.swift:68-70,89-97` | Use `showProgressIfReady()`, or show the year instead. |
| 14 | **Fixed.** `RemoteDetailView` keeps both a `Movie` and a `TVShow` query alive, with no `fetchLimit`, and both refetch after every save. Confirmed. | `RemoteDetailView.swift:8-16` | Query only `summary.kind`, with `fetchLimit = 1`. |
| 15 | **Fixed.** Discover and Search refetch every title's ID after every save (about 45 ms). Confirmed. | `AppState.swift:375-384` | Derive the IDs from the cached `appState.all(...)`. |
| 16 | **Fixed.** `allGenres()` fetches the whole library each time the smart-list editor opens. Confirmed. | `LibraryService+Collections.swift:170-174` | Derive the genres from `appState.all(...)`. |
| 17 | **Fixed.** `refreshStale` loads every ended show and then drops it in memory. Confirmed. | `LibraryService.swift:150-152` | Add the status to the predicate (nil counting as ongoing). |
| 18 | **Fixed.** A show refresh parses its JSON twice: once for the detail, once for the appended seasons. Payloads run from hundreds of KB to a few MB. Confirmed. | `TMDBClient.swift:118-120` | Decode one wrapper that reads both from the same decoder. |
| 19 | **Fixed.** `TMDBDate.parse` creates a new format style on every call, thousands of times per refresh. `TMDBDate.today` is called once per episode in the progress loop. Confirmed. | `TMDBModels.swift:182`, `WatchProgress.swift:85,112,122` | Use a static style, and compute `today` once per pass. |
| 20 | The base sync file is read and written on the main actor. Confirmed. | `DropboxSync.swift:230,433-441` | Move the read and write into `offMain` or a detached task. |
| 21 | CSV export goes through each show's episodes twice. Confirmed. | `Backup.swift:807-812` | Use `progressSummaries(in:)` once, plus a watched count. |
| 22 | **Fixed.** The movie page decodes its cast and directors JSON on every body evaluation. Confirmed. | `MovieDetailView.swift:36,123` | Reuse `DecodedCredits`, as the show page does. |
| 23 | **Left as is:** reading the progress map instead ties the menu to every save, which costs about as much as it saves. The Title menu calls `nextEpisodeToWatch()` on every evaluation. Confirmed. | `ToWatchDBApp.swift:192,207` | Read it from `appState.showProgress()`. |
| 24 | Library filters and genre sections scan the whole list on every keystroke. Confirmed. | `LibraryView.swift:43,96,358-364` | Cache the genre sections together with the list. |
| 25 | **Fixed.** Settings rebuilds about 250 country names with `Locale` lookups on every keystroke. Confirmed. | `SettingsView.swift:87-91,106` | Store `(code, name)` pairs in the static list. |
| 26 | Background progress rebuilds keep restarting during a sliced first sync or import. Plausible. | `AppState.swift:445-473,517-526` | Hold rebuilds until the apply finishes. |
| 27 | **Fixed.** Intents read the Keychain secrets for lookups that never use the network. Confirmed. | `Entities.swift:31,88`, `Intents.swift` | Use `LibraryService(context:client: nil)` for those. |
| 28 | **Fixed.** `DEAD_CODE_STRIPPING` is not set. Confirmed. | `project.yml` | Add `DEAD_CODE_STRIPPING: YES` to the target. |

## Dead or duplicated code

- `UpcomingService.upcomingMovies`, `upcomingEpisodes` and `upcoming(movies:shows:)`: only the tests call them.
- `TVShow.progress(asOf:)`: no callers. `nextEpisodeToAir(asOf:)`: only the tests call it.
- `StatsService.stats(movies:shows:…)`: only DebugTools and the tests call it.
- `SeerrAuthStore.load()` (`TokenStore.swift:59`): no callers.
- `NextToWatchView.swift:14,55`: filters `isAbandoned` twice.
- `CollectionShortcuts` runs the same 3 `@Query`s as its host `LibraryView`.
- `LibraryTransfer.swift:95-131`: the backup and CSV export branches are near copies.

## Suggested order

1. Findings 1, 4 and 13: send the Siri and Shortcuts paths through the progress map or a background context.
   It's a small change that removes multi-second main-thread stalls.
2. Finding 3, then 11: stop the smart lists and poster menus from loading each title's relationships.
3. Finding 9: the blank-poster bug.
4. Findings 2, 5 and 6: Dropbox sync. Do these together and back them with sync tests, since they change the
   merge path.
5. Everything else, as the code around each one gets touched.
