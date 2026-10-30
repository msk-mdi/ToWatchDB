# ToWatchDB: iOS performance and stability audit

Audited: version 2.1.0, commit `dd6e769`, on 2026-10-30. Static review of the app target and the
`ToWatchCore` package, read against the rules in [CODEBASE.md](CODEBASE.md). Numbers quoted from that guide
were measured on a Mac; iPhone CPUs are slower and iOS kills apps more readily, so each is marked where it
matters more on iOS.

## Summary

The codebase is already in good shape for iOS. The expensive work the guide describes (stats, the Siri hash,
backups, sync snapshots, JSON decoding, image decoding) runs off the main thread, saves are batched, model
writes skip unchanged fields, every write checks `isLive`, Swift 6 strict concurrency is on, Dropbox uploads
get a background task, and the secrets and store handle a locked iPhone. None of the findings below is a
data-loss bug.

What remains is mostly main-thread work that scales with library size and that the Mac tolerates but an
iPhone does not. The two findings that matter most share one cause: the full per-show progress index
(`TVShow.progressIndex`) is built on the main thread, and on iOS it is triggered shortly after every launch
by the Siri shortcut update, before the user has opened any list.

| # | Severity | Finding | Area |
|---|---|---|---|
| 1 | High, fixed | The Siri shortcut update builds the whole progress index on the main thread about a second after every launch | Launch, main thread |
| 2 | High, fixed | First visit to Up Next or Library, a new day, or a large refresh rebuilds the progress index on the main thread | Main thread |
| 3 | Medium, fixed | A launch before first unlock crashes on purpose (`fatalError`), including iOS prewarming and background Siri launches | Stability |
| 4 | Medium, fixed | Every launch fetches every movie and show in full to look for duplicates | Launch |
| 5 | Medium, fixed | A first Dropbox sync or a backup import writes the whole library on the main thread in one transaction | Main thread, memory |
| 6 | Medium, fixed | A refresh interrupted by backgrounding leaves titles stale for an hour and has no background task | Background |
| 7 | Low, fixed | Poster downloads are never cancelled and ignore Low Data Mode and cellular | Network, data |
| 8 | Low, fixed | Each visible episode row runs a query for its notes | Detail page |
| 9 | Low, fixed | Every title page opens a request to the Seerr server, which can wait 15 s off the home network | Network |
| 10 | Low | No `#Index` on the columns every predicate filters by | Store |
| 11 | Low | iPad rebuilds the page on every sidebar switch | iPad |
| 12 | Low | The decoded image cache is a 128 MB ceiling, with no reaction to memory warnings beyond NSCache's own | Memory |

## Findings

### 1. High: the Siri shortcut update builds the full progress index on the main thread after every launch

**Where.** [ToWatchDBApp.swift:44](../ToWatchDB/App/ToWatchDBApp.swift:44) runs on every activation: after a
one-second sleep it computes the Siri hash off the main thread, and if the hash differs from
`shortcutsContent` it calls `ToWatchShortcuts.updateAppShortcutParameters()`. That `@State` starts as `nil`
on every launch, so the comparison is always true the first time and the update runs at every launch.
The update makes the system call `ShowQuery.suggestedEntities()`
([Entities.swift:95](../ToWatchDB/Intents/Entities.swift:95)), which runs on the main actor and calls
`AppState.shared?.showProgress()` ([Entities.swift:101](../ToWatchDB/Intents/Entities.swift:101)). When nothing has filled the progress cache yet (the app opens on
Discover), `showProgress()` ([AppState.swift:309](../ToWatchDB/App/AppState.swift:309)) runs
`TVShow.progressIndex(in:)` on the main context: it fetches every season and every episode in full.

**Why it matters on iOS.** The guide (section 7, item 18) measured this at about 0.6 s for 300 shows on a Mac
and notes the old version "froze the app about a second after each launch (3 s with a large library)". The
hash was moved off the main thread, but the entity query still does the same walk on it. On an iPhone the
same walk is slower and lands while the user is scrolling Discover. It also happens whether or not Siri is
in use, and in Release builds signed ad hoc, where the system never runs the intents.

**Fixed (same day).** `ShowQuery.suggestedEntities()` now uses the app's progress map only when it is already
built and current (`showProgressIfReady`), and otherwise works everything out in a background context from
plain `Sendable` values. The shortcut hash is a stable FNV-1a hash (the old `Hasher` value changed every
launch, since its seed does) kept in UserDefaults, so a launch where nothing changed skips the update. The
launch also warms the progress map in the background (finding 2), so the main-thread map is usually ready
by the time the update runs.

Left as a follow-up: skipping the update entirely in builds without a team signature, where the system never
runs intents.

### 2. High: the progress index is rebuilt on the main thread on first use, at midnight, and after large refreshes

**Where.** `AppState.showProgress()` ([AppState.swift:309](../ToWatchDB/App/AppState.swift:309)) builds
the whole index synchronously when `progressCache` is nil or dated from another day. `noteProgressChanges`
([AppState.swift:370](../ToWatchDB/App/AppState.swift:370)) drops the cache after more than 2,000 changed
identifiers, which a refresh that brings in many newly announced episodes, a list import, or a first sync
reaches. The new-day rebuild is certain: the first list opened each day pays it. The first body of
`LibraryView` and `NextToWatchView` then runs the full rebuild on the main thread.

**Why it matters on iOS.** Same cost as finding 1, but triggered by a tap on Up Next or Library, so it shows
as a tab that does not respond. The episode fetch loads every column of every episode, including
`overview`, which is the largest string in the store, only to read five small fields.

**Fixed (same day).** The full index is now built in a background context
(`TVShow.progressSnapshotIndex`, a `Sendable` copy with episode IDs in place of models) and resolved on the
main context with one batch fetch of the next episodes (`ShowProgress.resolve`, 6 ms for 300 shows). The
launch warms it before the first list is opened; a new day, more than 2,000 changes, or an untraceable
deletion mark it for a rebuild and keep serving the last map meanwhile, with any entry pointing at a deleted
episode dropped first. The incremental per-show path is unchanged. Only a page that asks before the launch
warm-up lands (or a Siri launch, which has no warm-up) still builds on the main thread.

Measured while fixing: narrowing the episode fetch with `propertiesToFetch` to the five columns progress
reads saved nothing (0.41 s against 0.42 s for 21,600 episodes in a fresh context), so the cost is
materializing the objects, not the columns. That recommendation is withdrawn.

### 3. Medium: a launch before first unlock crashes by design, and iOS can launch the app then

**Where.** `SharedLibrary.openContainer` ([AppState.swift:621](../ToWatchDB/App/AppState.swift:621))
calls `fatalError` when the store file exists but cannot be opened because the device has not been unlocked
since boot. The container is created from `ToWatchDBApp`'s stored property initializer
(`@State private var appState = AppState()`), so it runs as soon as the process starts.

**Why it matters on iOS.** The app's own code already anticipates this case ("an iPhone launched in the
background before its first unlock"). The certain trigger is a Shortcuts automation or Siri request that
runs an intent without opening the app after a reboot: App Intents run in the app's process, which the
system launches in the background. iOS prewarming after a reboot may be another, depending on whether
SwiftUI instantiates the `App` struct during prewarming; Apple's guidance is not to touch protected data
from initializers for that reason. The store uses the default file protection, which is unavailable before
first unlock, so the launch hits the `fatalError`. Keeping the store rather than moving it aside is the
right call; crashing is not needed to achieve it, and a crash loop in the background shows up in the
Organizer's crash reports.

**Recommendation.**
- Keep the "locked" detection, but return a throwaway in-memory container flagged as `isPlaceholder`, and
  make `AppState` reopen the real store when the scene becomes active and
  `UIApplication.shared.isProtectedDataAvailable` is true. Intents can throw an "unlock your iPhone"
  error when the placeholder is in use.
- At minimum, defer `AppState()` from the `App` struct's property initializer to the first scene body, so
  prewarming never touches the store.

**Fixed (same day), the first recommendation.** On iOS, a store that exists but can't be read now opens an empty
in-memory placeholder (`SharedLibrary.isPlaceholder`) and logs, instead of crashing. `AppState.container` is
observed and swapped for the store when the scene becomes active (or an action or background refresh runs) with
protected data available: the save observer moves, every cache and the progress map are cleared, the launch's
repairs run, and the library refreshes and syncs. Syncs and refreshes skip the placeholder, and every intent and
entity query goes through `SharedLibrary.unlockedContainer` or `service`, which try to open the store and
otherwise throw `IntentError.locked`, so nothing is answered from or written to the placeholder. macOS keeps the
`fatalError`. The second recommendation wasn't needed: a prewarm before the first unlock gets the placeholder
too. Not run on a device: the path needs an iPhone restarted and not yet unlocked, and the first thing to check
there is a Shortcuts automation that runs an action (it should fail with the unlock message, not crash), then
unlocking and opening the app (the library should appear without a relaunch).

### 4. Medium: every launch fetches every movie and show in full to find duplicates

**Where.** `AppState.init` ([AppState.swift:173](../ToWatchDB/App/AppState.swift:173)) calls
`mergeDuplicateTitles` ([Backup.swift:535](../Packages/ToWatchCore/Sources/ToWatchCore/Services/Backup.swift:535)),
which fetches all movies and all shows sorted by date, every column included, on the main thread before the
first frame. It also calls `separateNotesSharingAnID`, which is cheap (a predicate fetch).

**Why it matters on iOS.** The guide measured a full title fetch at about 60 ms for 1,300 titles on a Mac.
On an iPhone it is more, and it is inside the launch window that iOS watches most closely. Duplicates are
a repair for an old sync bug and are expected to be absent.

**Recommendation.**
- Fetch only `tmdbID` with `propertiesToFetch` for the duplicate check, and run the full repair only when
  the IDs show a duplicate. Better still, compare `fetchCount` with the count of distinct IDs.
- Run the check after the first frame (from the root view's `.task`) rather than in `init`.

**Fixed (same day).** `init` now starts the check in a background context (`hasDuplicateTitles`, reading only the
IDs) and runs the repair on the main context only when it finds a copy. Every Dropbox sync and refresh waits for
it (`AppState.runDropboxSync`), since a sync applied over a copy deletes the other with its watch data, which is
why it ran in `init`.

Measured while fixing: fetching only `tmdbID` costs the same as fetching every column (45 ms against 44 ms for
1,300 titles in a fresh context on a Mac), as in finding 2, so the first recommendation saves nothing on its own
and is withdrawn. SwiftData has no count of distinct values, so the `fetchCount` comparison isn't available either.

### 5. Medium: a first sync or backup import writes the whole library on the main thread in one go

**Where.** `applySyncedBackup` ([LibrarySync.swift:404](../Packages/ToWatchCore/Sources/ToWatchCore/Services/LibrarySync.swift:404))
and `importBackup` ([Backup.swift:437](../Packages/ToWatchCore/Sources/ToWatchCore/Services/Backup.swift:437))
run on the main context. Decoding and merging are off the main thread, but creating thousands of models and
the single `commit()` are not.

**Why it matters on iOS.** A new device's first Dropbox sync with a few hundred shows inserts tens of
thousands of episodes on the main thread, then saves them in one transaction. The UI stops for the duration
and memory peaks with every model registered in the main context at once. It is a one-time event per device,
so it is Medium rather than High, but it is also the user's first impression of sync.

**Recommendation.**
- For the first-sync case (no `changes`), apply in a background `ModelContext(container)` and save there,
  then bump `libraryVersion` and clear the caches by hand (the `didSave` observer only watches the main
  context). Keep the incremental path on the main context, where it is fast.
- Alternatively, apply in chunks of shows with a save per chunk and `await Task.yield()` between them. The
  guide's reason for saving once (each save redraws every page) matters less during a one-off import behind
  a progress sheet.
- Show progress for the first sync; today the Settings row only shows a spinner.

**Fixed (same day).** Both now write in slices of about 500 titles and episodes, saving each and yielding the
main thread between them (`applySyncedBackupInSlices`, `importBackupInSlices`). Measured on a Mac with 300 shows of
72 episodes: the longest main-thread hold went from 3.3 s to 0.09 s, for the same total time. The sync apply keeps
its deletions for the last slice and stops when an edit lands between slices, so the sync merges again rather than
undo it; a partly applied sync is harmless because the base is only saved after a whole apply. The progress
display for the first sync is not done.

Measured while fixing: splitting the import into sub-backups that each go through `importBackup` was slower than
one go (4.2 s against 3.1 s), with each chunk holding the main thread 0.5 to 0.9 s, because every chunk read every
season and episode again. Each slice now reads only its own titles. The first recommendation, a background context, was not
tried: slicing keeps the apply on the main context, whose saves are what the app watches to bump the library
version, clear its caches, and schedule the next sync.

### 6. Medium: a launch refresh interrupted by backgrounding has no background task and leaves titles stale for an hour

**Where.** `AppState.refreshLibrary` ([AppState.swift:571](../ToWatchDB/App/AppState.swift:571)) runs at
launch and on activation. Unlike the Dropbox sync, it does not begin a `UIBackgroundTask`, and
`refreshLibraryIfDue` only retries after an hour.

**Why it matters on iOS.** Opening the app, glancing at Up Next, and switching away within seconds is the
common iPhone pattern. iOS suspends the app with the TMDB requests in flight; when it resumes, those
requests fail and their titles are skipped (`refreshStale` logs them as failed). Titles that were already
applied are saved, so nothing is lost, but the skipped ones stay stale until the next activation an hour
later. There is also no `BGAppRefreshTask`, so Upcoming and Up Next are only as fresh as the last foreground
session.

**Recommendation.**
- Wrap the launch refresh in `beginBackgroundTask`/`endBackgroundTask` like the sync, so a refresh that is
  nearly done can finish.
- Track failures: when a refresh ends with failed titles, let the next activation retry immediately instead
  of waiting an hour.
- Optional: schedule a `BGAppRefreshTask` (with the `fetch` background mode) that runs `refreshStale` and
  a Dropbox sync, so the lists are current when the app opens.

**Fixed (same day), all three.** `refreshLibrary` runs inside a `UIBackgroundTask` on iOS. `refreshStale` returns
a `RefreshOutcome` that counts titles whose download never got an answer (a `URLError` or cancellation, not an
error from TMDB, so a title TMDB removed doesn't retry forever); when there are any, the next activation refreshes
again. A background app refresh (`com.mehdi.towatchdb.refresh`) is requested when the scene goes to the
background and refreshes, then syncs. It uses SwiftUI's `.backgroundTask(.appRefresh)` scene modifier rather
than registering with `BGTaskScheduler` by hand: it registers the handler, completes the task when the work
returns, and cancels the work when iOS ends it. Not verified on a device: there is no simulator runtime here,
and background refresh needs a device anyway (`e -l objc -- (void)[[BGTaskScheduler sharedScheduler]
_simulateLaunchForTaskWithIdentifier:@"com.mehdi.towatchdb.refresh"]` in the debugger triggers it).

### 7. Low: poster downloads are never cancelled and ignore Low Data Mode and cellular

**Where.** `ImageCache.load` ([RemoteImage.swift:46](../ToWatchDB/Views/Components/RemoteImage.swift:46))
starts an unstructured detached task per image on `URLSession.shared`, by design so a scrolled-away view's
cancellation does not cancel a shared download. `RemoteImage.load` retries failures for up to two and a half
minutes per view.

**Why it matters on iOS.** Flicking through a 1,300-title grid on cellular requests every poster passed, at
w342 (about 30 to 60 KB each), and none of it is cancelled. The shared URL cache keeps them afterwards, so
it is a one-time cost per poster, but `URLSession` does not reduce usage in Low Data Mode on its own.

**Recommendation.**
- Cancel the shared download when the last waiter goes away (reference count the waiters in `inFlight`).
- Under `NWPathMonitor`'s `isConstrained` or `isExpensive`, request `.small` (w185) posters for grids and skip
  backdrops, or set `allowsConstrainedNetworkAccess = false` on the image requests and show placeholders.
- The retry loop is fine, but the 10 s first retry means an offline grid keeps 20 to 30 timers alive; a single
  shared "network came back" trigger would be cheaper.

**Fixed (same day), the first two.** `ImageCache.load` counts the views waiting for each download and cancels it
(`withTaskCancellationHandler`; `URLSession` stops the request) when the last one is cancelled; a view that stops
waiting while others still wait leaves it going. A new `NetworkConditions` (`NWPathMonitor`) reports Low Data
Mode: `PosterImage` asks for w185 instead of w342, and `BackdropImage` shows its gradient only. Only Low Data
Mode, not every expensive (cellular) path: that's the user's own setting for using less. The retry loop is left
as it is. Not measured on a device; Settings, Cellular after scrolling the grid is the check.

### 8. Low: each visible episode row runs a query for its notes

**Where.** `EpisodeRow` ([TVShowDetailView.swift:283](../ToWatchDB/Views/Detail/TVShowDetailView.swift:283))
reads `episode.notes` to decide whether to show the note glyph. Notes are a to-many relationship, so the
first read of each row faults with its own query. The rows are in a `LazyVStack`, so only visible rows pay,
but every season switch pays again.

**Recommendation.** The page already fetches the show's notes for `NotesSection`; fetch the episode notes of
the show once with a predicate on `note.episode?.season?.show` (or reuse `notesByOwner`) and pass a set of
episode IDs with notes down to the rows.

**Fixed (same day).** `LibraryService.episodesWithNotes` fetches the notes on episodes once (`#Predicate {
$0.episode != nil }`, nothing through the show, which the guide's predicate rules make awkward) and returns the
episodes' IDs, read without faulting the episodes in. The page caches it with `appState.cached` until the next
save, shared by every show page since it holds no models, and passes `hasNotes` to each row. Notes are few, so
not narrowing the fetch to the show costs nothing measurable.

### 9. Low: every title page opens a request to the Seerr server, which can wait 15 s away from home

**Where.** `SeerrRequestButton.watch` ([SeerrRequestButton.swift:135](../ToWatchDB/Views/Detail/SeerrRequestButton.swift:135))
runs on every title page when a server is set up, with a 15 s timeout
([SeerrClient.swift:139](../Packages/ToWatchCore/Sources/ToWatchCore/Seerr/SeerrClient.swift:139)).

**Why it matters on iOS.** A home-network server is unreachable on cellular. Each page then holds a request
open for 15 s and, on the first page, triggers the Local Network permission prompt. Nothing is shown while it
waits, so the cost is a wasted socket and a brief stall of the page's `.task`, not a visible spinner.

**Recommendation.** Remember the last failure and back off for a few minutes, or check `NWPathMonitor` for a
Wi-Fi path before trying a private address. Both are small changes.

**Fixed (same day), the first.** A status check that fails with a `URLError` (no answer, as opposed to an error
from Seerr) is remembered in `AppState`, and title pages skip their check for 5 minutes after it. Test Connection
in Settings and signing in clear it. The first page off the home network still waits for its timeout, and its
Local Network prompt is unchanged.

### 10. Low: no `#Index` on the columns the predicates filter by

**Where.** [Models.swift](../Packages/ToWatchCore/Sources/ToWatchCore/Models/Models.swift) has no
`#Index`. `movie(tmdbID:)`, `show(tmdbID:)`, the refresh predicates on `lastRefreshed` and `releaseDate`,
and Upcoming's predicate on `airDate` and `isWatched` all scan the table.

**Why it matters on iOS.** At current sizes (a few thousand titles, tens of thousands of episodes) SQLite
scans these in milliseconds, so this is Low. It becomes worth doing when a schema version is added for
another reason, since the guide notes an index alone is not treated as a migration and existing stores never
get it.

### 11. Low: iPad rebuilds the whole page on every sidebar switch

**Where.** [RootView.swift:179](../ToWatchDB/Views/RootView.swift:179) wraps the detail in a
`NavigationStack` with `.id(appState.selectedTab)` on iOS, while macOS uses `PageHost`.

**Why it matters.** The guide measured a cold page build at 100 to 350 ms on a Mac. On an iPad, switching
Library to Up Next and back rebuilds both. The cached lists keep it short, but the poster grid still
re-measures and refills. `PageHost` was written to be platform-neutral; enabling it for the iPad regular
width would make sidebar switches instant there too.

### 12. Low: the decoded image cache is a 128 MB ceiling with no app-level reaction to memory warnings

**Where.** `ImageCache` ([RemoteImage.swift:17](../ToWatchDB/Views/Components/RemoteImage.swift:17)) is an
`NSCache` with a 128 MB cost limit on iOS. The derived caches in `AppState` (`derivedCache`,
`responseCache`, `titleCache`, `offMainCache`) have no limit and no memory-warning handling.

**Why it matters on iOS.** `NSCache` evicts under memory pressure on its own, so the posters are fine. The
`AppState` caches are small (arrays of model references and an hour of TMDB detail payloads) and are the
right trade. This is Low: worth a `UIApplication.didReceiveMemoryWarningNotification` observer that clears
`responseCache` and the stale `derivedCache` entries, mostly so that a jetsam report never names the app.

## What is already right for iOS

Listed so the next pass does not undo them.

- Stats, the Siri hash, backups, CSV export, sync snapshots, JSON decoding, merging, and image decoding all
  run off the main thread in their own `ModelContext` or detached task.
- `LibraryService` saves once per batch, `Episode.apply` writes only changed fields, and every setter checks
  `isLive` after an `await`.
- Dropbox sync begins a `UIBackgroundTask` on backgrounding, skips unchanged files with one metadata request,
  compresses the upload, and never saves half a merge.
- Secrets use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, a failed read is not treated as signed
  out, and the store handles the locked-at-launch case without moving data aside.
- TMDB requests have a 20 s timeout, their own cache sized for the season payloads, a single 429 retry, and
  one request per show for seasons 0 to 16.
- `#Predicate` bodies avoid force unwraps, fetches use `propertiesToFetch` and `relationshipKeyPathsForPrefetching`
  where it was measured to matter, and the only `fatalError`s are in store opening, when even an in-memory store
  can't be made (and on a Mac, for a store it can't read).
- Swift 6 strict concurrency is complete, `ImageCache` is the only `@unchecked Sendable`, and it is guarded
  by a lock.

## How to measure on a device

The findings above are from reading the code. To confirm the priorities with numbers:

1. Seed a large library (a backup with 300 shows) on a mid-range iPhone, not the simulator.
2. Instruments, Time Profiler with the Hangs track: launch, wait 3 s on Discover (finding 1), then tap Up
   Next (finding 2). Hangs over 250 ms are what the system reports as app hangs.
3. The SwiftData instrument (Core Data template): count fetches while opening a show page and switching
   seasons (finding 8), and during a first sync (finding 5).
4. Xcode Organizer, Hangs and Disk Writes reports, once a build with a team signature has run on a device
   for a few days. MetricKit's `MXAppLaunchMetric` and `MXAppResponsivenessMetric` give the same in the
   field.
5. Settings, Cellular, after a session of scrolling the grid on cellular, for finding 7.

## Suggested order

1. Findings 1 and 2 together: done (build the index off the main thread). This removes the largest hang on
   every launch.
2. Finding 4: a one-line `propertiesToFetch` change with a measurable launch win.
3. Finding 3: stop crashing before first unlock.
4. Finding 6: a background task around the launch refresh.
5. Findings 5, 7, 8, 9 as time allows. Findings 10, 11, 12 when the related code is next touched.

## Verification run for this audit

Run on 2026-10-30 with Xcode 27.2 on this Mac, to confirm the baseline the findings are read against:

- `xcodegen generate` then `xcodebuild -scheme ToWatchDB -destination 'generic/platform=iOS Simulator'`
  with `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`, as CI does: build succeeded, no warnings.
- `swift test` in `Packages/ToWatchCore`: 75 tests in 2 suites passed.
- No iOS Simulator runtime is installed on this Mac, so nothing was run or profiled on a device or
  simulator. Every finding is from reading the code; the measurements quoted are the guide's own Mac numbers.

After fixing findings 1 and 2, the same day: the iOS Simulator and macOS builds pass with warnings as
errors, and the core suite passes with 76 tests (one new, for the snapshot round trip and a deletion between
snapshot and resolve). The fix was not run on a device either: the first thing to check there is the Hangs
track in Time Profiler during the first 3 s after launch and on the first tap of Up Next.
