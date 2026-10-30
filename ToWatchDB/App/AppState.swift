#if os(iOS)
import BackgroundTasks
#endif
import Foundation
import Observation
import SwiftUI
import SwiftData
import ToWatchCore

enum AppTab: Hashable {
    case discover, search, all, movies, shows, nextToWatch, upcoming, backlog, watched, organize, stats
    case space(UUID), tag(UUID), smartList(UUID)
}

/// App-wide state: the model container, TMDB configuration, navigation, and background refresh.
@Observable @MainActor
final class AppState {
    /// The app's state, for Siri and Shortcuts actions, when its library is the one they use.
    static weak var shared: AppState?

    /// The library. Observed: the scenes' `.modelContainer` follows it when the library on disk opens after a launch
    /// before the first unlock, which started with a placeholder (`SharedLibrary.isPlaceholder`).
    private(set) var container: ModelContainer

    var selectedTab: AppTab = .discover
    /// Tab bar layouts: a library scope to show in the Library tab's scope picker.
    var requestedLibraryScope: LibraryScope?
    /// Open main windows (macOS keeps running with none), so menu commands can reopen one.
    var mainWindowCount = 0
    /// Discover's trending lists, kept across page switches so Discover doesn't refetch and redraw every visit.
    var trending: Trending?
    /// Why the trending lists couldn't load, if they couldn't.
    private(set) var trendingError: String?

    struct Trending {
        let movies: [MediaSummary]
        let shows: [MediaSummary]
        let token: String
        let language: String
        let loadedAt: Date

        func isFresh(token: String?, language: String, now: Date = .now) -> Bool {
            token == self.token && language == self.language && now.timeIntervalSince(loadedAt) < 30 * 60
        }
    }
    /// iOS presents Settings as a sheet (macOS uses the Settings scene).
    var isShowingSettings = false
    /// A backup, CSV export, or import requested from the File menu.
    var fileRequest: LibraryFileRequest?
    /// The space, tag, or smart list being created or edited, if any.
    var collectionEditor: CollectionEditorTarget?
    private(set) var isRefreshing = false
    var errorMessage: String?

    private(set) var tokenOverride: String? {
        didSet { tokenVersion += 1 }
    }
    /// Bumped whenever the TMDB token changes. Views that must load again then key their tasks on this, not on
    /// the token itself: a secret has no place in view identity.
    private(set) var tokenVersion = 0
    /// The user's OMDb API key; without one the app fetches no IMDb ratings.
    private(set) var omdbKey: String?

    /// The Seerr server titles are requested on, and how the app signs in to it.
    private(set) var seerrServer: String = UserDefaults.standard.string(forKey: "seerrServer") ?? ""
    private(set) var seerrAuth: SeerrAuth?
    /// The secrets couldn't be read at launch (an iPhone launched in the background while locked), so they're
    /// read again when the app comes to the front. Otherwise TMDB and Seerr stayed signed out until a relaunch.
    @ObservationIgnored private var secretsUnread = false
    /// Who the app is signed in to Seerr as, for Settings.
    private(set) var seerrUserName: String? = UserDefaults.standard.string(forKey: "seerrUserName")

    /// Loads Discover's trending lists, unless fresh ones are cached. Here rather than in Discover so the
    /// Mac window's Refresh button can reload them.
    func loadTrending(force: Bool = false) async {
        guard let client, let token else { return }
        if !force, trending?.isFresh(token: token, language: language) == true { return }
        trendingError = nil
        let language = language, started = Date.now
        // Two loads can overlap (the page and the Refresh button, or a token or language change). One counts only
        // if it's still for the current settings and no newer one landed meanwhile.
        func isLatest() -> Bool {
            token == self.token && language == self.language && (trending.map { $0.loadedAt <= started } ?? true)
        }
        do {
            async let movies = client.trendingMovies()
            async let shows = client.trendingTVShows()
            let loaded = Trending(movies: try await movies.results.map(MediaSummary.init),
                                  shows: try await shows.results.map(MediaSummary.init),
                                  token: token, language: language, loadedAt: started)
            guard isLatest() else { return }
            trending = loaded
            trendingError = nil
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            // A failed older load mustn't hide what a newer one loaded.
            guard isLatest() else { return }
            trendingError = error.localizedDescription
        }
    }

    let dropbox = DropboxSync(client: DropboxClient.bundledAppKey.map { DropboxClient(appKey: $0) }, vault: .secretStore)
    /// Sample-data and snapshot runs use a throwaway library, which must never reach Dropbox.
    private let isInMemory: Bool
    @ObservationIgnored private var dropboxDelay: Task<Void, Never>?
    /// Whether a sync was put off until the running refresh ends.
    @ObservationIgnored private var syncsAfterRefresh = false
    /// When `refreshLibrary` last started.
    @ObservationIgnored private var lastRefresh: Date?
    /// Whether a refresh already said TMDB turned the token down.
    @ObservationIgnored private var hasReportedRejectedToken = false
    #if os(iOS)
    @ObservationIgnored private var backgroundSync: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var backgroundRefresh: UIBackgroundTaskIdentifier = .invalid
    #endif

    /// TMDB `language` parameter; empty means follow the system.
    var language: String = UserDefaults.standard.string(forKey: "tmdbLanguage") ?? "" {
        didSet { UserDefaults.standard.set(language, forKey: "tmdbLanguage") }
    }

    /// Country for Where to Watch (ISO 3166-1 code). Defaults to the device's region.
    var watchRegion: String = UserDefaults.standard.string(forKey: "watchRegion")
        ?? Locale.current.region?.identifier ?? "US" {
        didSet { UserDefaults.standard.set(watchRegion, forKey: "watchRegion") }
    }

    /// Bumped on every save, so caches of derived data (stats) know when the library changed. Observed: a view
    /// that reads a cached value redraws after every save even when its last body didn't touch the models.
    private(set) var libraryVersion = 0
    /// The version of the last save that deleted something. Stale values from before it may hold deleted
    /// models, which crash when read, so `allowStale` doesn't serve them.
    @ObservationIgnored private var lastDeletionVersion = 0
    @ObservationIgnored private var derivedCache: [String: (version: Int, value: Any)] = [:]
    /// The day `derivedCache` was last emptied: many keys include the day, so older entries are never read again.
    @ObservationIgnored private var derivedCacheDay = Calendar.current.startOfDay(for: .now)
    @ObservationIgnored private var saveObserver: (any NSObjectProtocol)?

    init(inMemory: Bool = false) {
        isInMemory = inMemory
        container = inMemory == SharedLibrary.isInMemory ? SharedLibrary.container : SharedLibrary.makeContainer(inMemory: inMemory)
        loadSecrets()
        if container === SharedLibrary.container {
            Self.shared = self
            errorMessage = SharedLibrary.openFailure
        }
        attachLibrary()
        #if os(macOS)
        AppDelegate.appState = self
        #endif
    }

    /// Whether the library is the empty stand-in for one that can't be read yet. Nothing syncs or refreshes into it.
    private var isPlaceholder: Bool { container === SharedLibrary.container && SharedLibrary.isPlaceholder }

    /// Watches the container's saves and repairs its library: at launch, and again when the library on disk opens
    /// after a launch with the placeholder.
    private func attachLibrary() {
        if let saveObserver { NotificationCenter.default.removeObserver(saveObserver) }
        saveObserver = NotificationCenter.default.addObserver(
            // No queue: the version must change synchronously with the save, before any view redraws with the
            // new data, or a redraw could store a value computed from stale data under the new version.
            forName: ModelContext.didSave, object: container.mainContext, queue: nil
        ) { [weak self] notification in
            func identifiers(_ key: ModelContext.NotificationKey) -> [PersistentIdentifier] {
                notification.userInfo?[key.rawValue] as? [PersistentIdentifier] ?? []
            }
            let deleted = identifiers(.deletedIdentifiers)
            let inserted = identifiers(.insertedIdentifiers)
            let changed = inserted + identifiers(.updatedIdentifiers)
            MainActor.assumeIsolated {
                guard let self else { return }
                self.libraryVersion += 1
                if !deleted.isEmpty {
                    self.lastDeletionVersion = self.libraryVersion
                    // Nothing cached before a deletion is served again, and it may hold the deleted models.
                    self.derivedCache.removeAll()
                }
                if (inserted + deleted).contains(where: { Self.titleEntities.contains($0.entityName) }) { self.titleCache.removeAll() }
                self.noteProgressDeletions(deleted)
                self.noteProgressChanges(changed)
                if !self.isInMemory { self.dropbox.noteSave() }
                // Here rather than in a view: on Mac, edits from a title window, Settings, or Siri with the main
                // window closed weren't synced until it reopened.
                if self.libraryVersion != self.dropbox.syncedVersion { self.syncWithDropbox(after: .seconds(5)) }
            }
        }
        guard container === SharedLibrary.container, !isPlaceholder else { return }
        LibraryService.saveFailed = { [weak self] error in
            self?.errorMessage = "A change couldn't be saved, so it was undone. (\(error.localizedDescription))"
        }
        library.separateNotesSharingAnID()
        duplicateRepair = Task { await mergeDuplicateTitles() }
    }

    /// Switches to the library on disk once `SharedLibrary` could open it in place of the placeholder (the app was
    /// launched before the iPhone's first unlock), dropping everything worked out from the empty placeholder.
    func libraryOpened() {
        guard container !== SharedLibrary.container, !SharedLibrary.isPlaceholder else { return }
        container = SharedLibrary.container
        titleCache.removeAll()
        derivedCache.removeAll()
        offMainCache.removeAll()
        responseCache.removeAll()
        shortcutsHash = nil
        progressCache = nil
        progressChanges = []
        progressRebuildNeeded = false
        // Pages redraw, and nothing cached from the placeholder is served, stale or not.
        libraryVersion += 1
        lastDeletionVersion = libraryVersion
        attachLibrary()
        warmShowProgress()
        // The launch's refresh skipped the placeholder.
        Task { await refreshLibrary() }
        syncWithDropbox()
    }

    /// The launch's repair of titles held twice. Syncs and refreshes wait for it: a sync applied over a copy would
    /// keep one and delete the other with its watch data.
    @ObservationIgnored private var duplicateRepair: Task<Void, Never>?

    /// Looks for a title held twice in a context of its own, and folds copies together only if there are any
    /// (there shouldn't be). Checking on the main thread held up the first frame of every launch.
    private func mergeDuplicateTitles() async {
        let container = container
        let found = await Task.detached(priority: .userInitiated) {
            (try? LibraryService.hasDuplicateTitles(in: ModelContext(container))) ?? true
        }.value
        guard found else { return }
        do { try library.mergeDuplicateTitles() } catch {
            Log.library.error("Couldn't merge duplicate titles: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadSecrets() {
        do {
            tokenOverride = try TokenStore.read()
            omdbKey = try OMDbKeyStore.read()
            seerrAuth = try SeerrAuthStore.read()
            secretsUnread = false
        } catch {
            Log.secrets.error("The secrets couldn't be read at launch; trying again when the app comes to the front")
            secretsUnread = true
        }
    }

    /// Computes a value derived from the library once per library version. Stats walk every episode,
    /// which made opening the Stats page stall; until something is saved, the result can't change.
    /// Reading it makes the calling view depend on `libraryVersion`; the cache itself isn't observed, so
    /// filling it from a view's body is safe.
    ///
    /// `allowStale` returns the last value even if the library changed since. Pages kept alive offscreen pass
    /// it so a save doesn't make every hidden page recompute; they catch up when they're shown again.
    func cached<T>(_ key: String, allowStale: Bool = false, _ compute: () -> T) -> T {
        let libraryVersion = libraryVersion
        let today = Calendar.current.startOfDay(for: .now)
        if today != derivedCacheDay {
            derivedCache.removeAll()
            derivedCacheDay = today
        }
        if let entry = derivedCache[key],
           entry.version == libraryVersion || (allowStale && entry.version >= lastDeletionVersion),
           let value = entry.value as? T {
            return value
        }
        let value = compute()
        derivedCache[key] = (libraryVersion, value)
        return value
    }

    /// Values worked out off the main thread by `computeOffMain`, with the library version they're from. They hold
    /// no models, so one from an older version (or from before a deletion) is safe to show until it's replaced.
    /// Observed: a page reading one redraws when its new value lands.
    private var offMainCache: [String: (version: Int, value: any Sendable)] = [:]
    @ObservationIgnored private var offMainCacheDay = Calendar.current.startOfDay(for: .now)

    /// The value last worked out for `key`, from any library version, or nil if there's none yet.
    func offMainValue<T: Sendable>(_ key: String, as type: T.Type = T.self) -> T? {
        offMainCache[key]?.value as? T
    }

    /// Works `key` out again in a context of its own, from what's saved, unless it's already from the current
    /// library version. Stats walk every watched title and episode: in a view's body they held the main thread
    /// for about 0.45 s (300 shows) after every save while the page was showing.
    func computeOffMain<T: Sendable>(_ key: String, _ work: @escaping @Sendable (ModelContext) -> T) async {
        let version = libraryVersion, today = Calendar.current.startOfDay(for: .now)
        if today != offMainCacheDay {
            // Many keys include the day, so older entries are never read again.
            offMainCache = offMainCache.filter { $0.key == key }
            offMainCacheDay = today
        }
        if let entry = offMainCache[key], entry.version == version { return }
        let container = container
        let value = await Task.detached(priority: .userInitiated) { work(ModelContext(container)) }.value
        // Still kept if the page moved on: it's right for `version`. A newer one that landed first wins.
        if offMainCache[key].map({ $0.version <= version }) ?? true { offMainCache[key] = (version, value) }
    }

    /// Every model of a type, for `cached` closures. Pages used to `@Query` these, which refetched whole tables
    /// after every save even when the cached value was reused (and on hidden pages kept alive on Mac).
    ///
    /// Movies and shows are kept until a save inserts or deletes one: a grid fetched them again after every save
    /// (about 60 ms for 1,300 titles), though an edit changes a title's sort keys and filters, not which titles there
    /// are. Filter the result in memory rather than fetching with a predicate.
    func all<T: PersistentModel>(_ type: T.Type = T.self) -> [T] {
        let key = ObjectIdentifier(T.self)
        // A title rolled back after a failed save is gone from the context; one deleted since isn't live either.
        if let cached = titleCache[key] as? [T] { return cached.filter(\.isLive) }
        let models = (try? container.mainContext.fetch(FetchDescriptor<T>())) ?? []
        if Self.titleEntities.contains(String(describing: T.self)) { titleCache[key] = models }
        return models
    }

    @ObservationIgnored private var titleCache: [ObjectIdentifier: [any PersistentModel]] = [:]
    private static let titleEntities: Set<String> = ["Movie", "TVShow"]

    /// A hash of what Siri is taught: title names and each show's next episode. Worked out off the main thread
    /// from what's saved, once per library version and day: it walks every episode, which froze the app about
    /// a second after each launch (3 s with a large library) when it ran on the main context.
    func shortcutsContent() async -> Int {
        let version = libraryVersion, day = Calendar.current.startOfDay(for: .now)
        if let shortcutsHash, shortcutsHash.version == version, shortcutsHash.day == day { return shortcutsHash.value }
        let container = container
        let value = await Task.detached(priority: .utility) { Self.shortcutsContent(in: ModelContext(container)) }.value
        // Under the version it started from: a save meanwhile makes the next call work it out again.
        shortcutsHash = (version, day, value)
        return value
    }

    @ObservationIgnored private var shortcutsHash: (version: Int, day: Date, value: Int)?

    /// A stable hash (FNV-1a), not `Hasher`: its seed changes with every launch, so the value kept from the last
    /// launch would never match and Siri was taught again (asking for every show's progress) at every launch.
    /// Titles in ID order for the same reason: a fetch without a sort doesn't promise one.
    private nonisolated static func shortcutsContent(in context: ModelContext) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func combine(_ string: String?) {
            for byte in (string ?? "").utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
            hash = (hash ^ (string == nil ? 0x1e : 0x1f)) &* 0x0000_0100_0000_01b3 // Ends the field; nil isn't "".
        }
        var movies = FetchDescriptor<Movie>(sortBy: [SortDescriptor(\.tmdbID)])
        movies.propertiesToFetch = [\.title]
        for movie in (try? context.fetch(movies)) ?? [] { combine(movie.title) }
        let progress = (try? TVShow.progressSummaries(in: context)) ?? [:]
        for show in (try? context.fetch(FetchDescriptor<TVShow>(sortBy: [SortDescriptor(\.tmdbID)]))) ?? [] {
            combine(show.name)
            combine(progress[show.persistentModelID]?.nextEpisode?.code)
        }
        return Int(truncatingIfNeeded: hash)
    }

    /// The TMDB IDs in the library, for Discover and Search badges. Reads only the IDs. Hidden pages (kept alive
    /// on Mac) pass `allowStale` so a save doesn't refetch them for a page nobody sees.
    func libraryIDs(allowStale: Bool = false) -> LibraryIDs {
        cached("library-ids", allowStale: allowStale) {
            var movies = FetchDescriptor<Movie>()
            movies.propertiesToFetch = [\.tmdbID]
            var shows = FetchDescriptor<TVShow>()
            shows.propertiesToFetch = [\.tmdbID]
            let context = container.mainContext
            return LibraryIDs(movies: (try? context.fetch(movies)) ?? [], shows: (try? context.fetch(shows)) ?? [])
        }
    }

    /// Every show's progress, shared by the pages that need it (library grids, Next to Watch): a show's progress
    /// walks all of its episodes. It fetches every show itself, so a page whose query is narrower can't cache a
    /// partial map. Kept across saves: a save recomputes only the shows it changed, where recomputing every show
    /// walked every episode in the library after each click.
    ///
    /// The full map is built in a context of its own off the main thread (`rebuildShowProgress`): at launch, before
    /// any page asks (`warmShowProgress`), and again on a new day or after more changes than are worth tracing,
    /// the last map serving meanwhile. Built on the main thread, it froze the first list opened each day for
    /// about a second per 300 shows, longer on an iPhone. Only a page that asks before the launch warm-up lands
    /// (or a Siri launch, which has no warm-up) still builds it here.
    func showProgress() -> [PersistentIdentifier: ShowProgress] {
        _ = libraryVersion // Pages showing progress redraw after saves.
        _ = progressGeneration // And when a map built in the background lands.
        let day = Calendar.current.startOfDay(for: .now)
        let context = container.mainContext
        guard var cache = progressCache else {
            let index = (try? TVShow.progressIndex(in: context)) ?? (progress: [:], showOf: [:])
            progressCache = (day, index.progress, index.showOf)
            progressChanges = []
            progressRebuildNeeded = false
            return index.progress
        }
        if cache.day != day || progressRebuildNeeded {
            rebuildShowProgressLater()
            return cache.progress
        }
        guard !progressChanges.isEmpty else { return cache.progress }
        var shows: [PersistentIdentifier: TVShow] = [:]
        for id in progressChanges {
            let show: TVShow? = switch context.model(for: id) {
            case let show as TVShow: show
            case let season as Season: season.show
            case let episode as Episode: episode.season?.show
            default: nil
            }
            guard let show, show.isLive else { continue }
            shows[show.persistentModelID] = show
            if id.entityName != "TVShow" { cache.showOf[id] = show.persistentModelID }
        }
        for (id, show) in shows { cache.progress[id] = show.progressSummary() }
        progressCache = cache
        progressChanges = []
        return cache.progress
    }

    /// Builds the progress map in the background if there's none yet, so the first list opened finds it ready.
    /// Called once the first frame is up.
    func warmShowProgress() {
        guard progressCache == nil else { return }
        rebuildShowProgressLater()
    }

    /// The progress map if it's built and current, without building it. The Siri entity query asks: with none
    /// ready, it works its own out in the background rather than making the main thread do it.
    func showProgressIfReady() -> [PersistentIdentifier: ShowProgress]? {
        guard let cache = progressCache, cache.day == Calendar.current.startOfDay(for: .now), !progressRebuildNeeded else { return nil }
        return showProgress()
    }

    private func rebuildShowProgressLater() {
        guard progressRebuild == nil else { return }
        progressRebuild = Task {
            await rebuildShowProgress()
            progressRebuild = nil
        }
    }

    /// Works every show's progress out in a context of its own and swaps it in. A save landing meanwhile would
    /// leave the map behind it (a change noted during the build can't be told from one the build saw), so then
    /// it's built again, a few times at most; the next page redraw asks again after that.
    private func rebuildShowProgress() async {
        for _ in 1...3 {
            let version = libraryVersion, day = Calendar.current.startOfDay(for: .now), container = container
            let index = await Task.detached(priority: .userInitiated) {
                try? TVShow.progressSnapshotIndex(in: ModelContext(container))
            }.value
            guard let index else { return }
            guard version == libraryVersion else { continue }
            // A page built the map itself meanwhile (before the warm-up landed): it's the same map.
            if let cache = progressCache, cache.day == day, !progressRebuildNeeded { return }
            guard let progress = try? ShowProgress.resolve(index.progress, in: container.mainContext) else { return }
            progressCache = (day, progress, index.showOf)
            progressChanges = []
            progressRebuildNeeded = false
            progressGeneration += 1
            return
        }
    }

    /// `showProgress` as of `day`, with the show each season and episode it read belongs to; and the shows,
    /// seasons, and episodes saved since, which it recomputes.
    @ObservationIgnored private var progressCache: (day: Date, progress: [PersistentIdentifier: ShowProgress],
                                                    showOf: [PersistentIdentifier: PersistentIdentifier])?
    @ObservationIgnored private var progressChanges: [PersistentIdentifier] = []
    /// Whether the map must be built again from scratch; until the build lands, the current one serves.
    @ObservationIgnored private var progressRebuildNeeded = false
    @ObservationIgnored private var progressRebuild: Task<Void, Never>?
    /// Bumped when a map built in the background lands. Observed, so pages showing progress redraw with it.
    private var progressGeneration = 0
    /// The models a show's progress is worked out from.
    private static let progressEntities: Set<String> = ["TVShow", "Season", "Episode"]

    /// Drops deleted shows and queues the shows that lost a season or episode. A deletion used to rebuild every
    /// show's progress, reading every episode again (about 0.7 s for 300 shows), when a refresh dropped one episode.
    /// A season or episode saved since the progress was last read can't be traced to its show (deleted, it can't be
    /// read), so then everything is worked out again, in the background. Either way, no entry that points at a
    /// deleted episode is kept: the map serves until the rebuild lands, and a deleted model can't be read.
    private func noteProgressDeletions(_ deleted: [PersistentIdentifier]) {
        let deleted = deleted.filter { Self.progressEntities.contains($0.entityName) }
        guard !deleted.isEmpty, var cache = progressCache else { return }
        let deletedIDs = Set(deleted)
        var shows: [PersistentIdentifier] = []
        for id in deleted where id.entityName != "TVShow" {
            guard let show = cache.showOf.removeValue(forKey: id) else {
                progressRebuildNeeded = true
                continue
            }
            if !deletedIDs.contains(show) { shows.append(show) }
        }
        for id in deleted where id.entityName == "TVShow" { cache.progress[id] = nil }
        if deleted.contains(where: { $0.entityName != "TVShow" }) {
            cache.progress = cache.progress.filter { _, progress in
                progress.nextEpisode?.isLive != false && progress.nextEpisodeToAir?.isLive != false
            }
        }
        progressCache = cache
        // A deleted model can't be read to find its show.
        progressChanges.removeAll { deletedIDs.contains($0) }
        progressChanges += shows
    }

    private func noteProgressChanges(_ changed: [PersistentIdentifier]) {
        guard progressCache != nil else { return }
        progressChanges += changed.filter { Self.progressEntities.contains($0.entityName) }
        // A refresh of the whole library: computing everything again (in the background) is cheaper than finding
        // each show.
        if progressChanges.count > 2000 {
            progressRebuildNeeded = true
            progressChanges = []
        }
    }

    /// TMDB responses for detail pages (where to watch, previews), kept for an hour so reopening a title shows
    /// them at once instead of a spinner and a round trip.
    @ObservationIgnored private var responseCache: [String: (value: any Sendable, loadedAt: Date)] = [:]

    func cachedResponse<T: Sendable>(_ key: String, maxAge: TimeInterval = 3600,
                                     _ fetch: () async throws -> T) async throws -> T {
        let key = "\(key)-\(language)"
        if let entry = responseCache[key], Date.now.timeIntervalSince(entry.loadedAt) < maxAge, let value = entry.value as? T {
            return value
        }
        let value = try await fetch()
        // Entries are an hour old at most when read, so older ones only take memory (credits, provider lists).
        responseCache = responseCache.filter { Date.now.timeIntervalSince($0.value.loadedAt) < 3600 }
        responseCache[key] = (value, .now)
        return value
    }

    /// The cached response, if there's a fresh one, without fetching.
    func cachedResponse<T: Sendable>(_ key: String, maxAge: TimeInterval = 3600) -> T? {
        guard let entry = responseCache["\(key)-\(language)"], Date.now.timeIntervalSince(entry.loadedAt) < maxAge else { return nil }
        return entry.value as? T
    }

    var token: String? { tokenOverride ?? TokenStore.bundledToken }
    var hasBundledToken: Bool { TokenStore.bundledToken != nil }

    var client: TMDBClient? { SharedLibrary.makeClient(token: token, language: language) }

    /// IMDb ratings client, if an OMDb key is saved.
    var imdb: IMDbClient? { omdbKey.map { IMDbClient(apiKey: $0) } }

    var library: LibraryService { LibraryService(context: container.mainContext, client: client, imdb: imdb) }

    func setTokenOverride(_ token: String?) {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        hasReportedRejectedToken = false
        if trimmed.isEmpty {
            noteSecretFailure(TokenStore.delete())
            tokenOverride = nil
        } else {
            noteSecretFailure(TokenStore.save(trimmed))
            tokenOverride = trimmed
        }
    }

    func setOMDbKey(_ key: String?) {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            noteSecretFailure(OMDbKeyStore.delete())
            omdbKey = nil
        } else {
            noteSecretFailure(OMDbKeyStore.save(trimmed))
            omdbKey = trimmed
        }
    }

    /// The change still applies until the app quits; without the alert, it looked saved and was gone after a relaunch.
    private func noteSecretFailure(_ succeeded: Bool) {
        if !succeeded { errorMessage = "The change couldn't be saved on this device, so it will be undone when the app restarts." }
    }

    /// Seerr client for requesting titles, if a server is set up.
    var seerr: SeerrClient? { seerrAuth.flatMap { SeerrClient(server: seerrServer, auth: $0) } }

    /// Saves a connected Seerr client and who it's signed in as; `nil` forgets the server and sign-in.
    func setSeerr(_ client: SeerrClient?, userName: String? = nil) {
        let defaults = UserDefaults.standard
        if let client {
            defaults.set(client.baseURL.absoluteString, forKey: "seerrServer")
            defaults.set(userName, forKey: "seerrUserName")
            noteSecretFailure(SeerrAuthStore.save(client.auth))
            seerrServer = client.baseURL.absoluteString
            seerrAuth = client.auth
            seerrUserName = userName
        } else {
            defaults.removeObject(forKey: "seerrServer")
            defaults.removeObject(forKey: "seerrUserName")
            noteSecretFailure(SeerrAuthStore.delete())
            seerrServer = ""
            seerrAuth = nil
            seerrUserName = nil
        }
    }

    /// Runs a library operation and surfaces any error as an alert.
    func perform(_ operation: @MainActor (LibraryService) async throws -> Void) async {
        do {
            try await operation(library)
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Syncs with Dropbox if connected. `delay` coalesces a burst of edits into one sync; a later call
    /// restarts the wait. A sync already running finishes, then runs once more.
    func syncWithDropbox(after delay: Duration = .zero) {
        dropbox.checkConnectionIfNeeded()
        guard dropbox.isConnected, !isInMemory else { return }
        dropboxDelay?.cancel()
        dropboxDelay = Task {
            if delay > .zero {
                try? await Task.sleep(for: delay)
                // The sync that ran meanwhile may have covered these changes (its own save bumps the version too).
                guard !Task.isCancelled, libraryVersion != dropbox.syncedVersion else { return }
            }
            // A merge saves a refresh's changes so far, which makes it snapshot and merge again, once per title
            // the refresh updates meanwhile. The refresh syncs when it's done instead.
            guard !isRefreshing else {
                syncsAfterRefresh = true
                return
            }
            // Its own task, so a later call's cancel can't interrupt a sync midway.
            Task { await runDropboxSync() }
        }
    }

    /// Every sync starts here, after the launch's duplicate repair, and never from the placeholder: merging the file
    /// into an empty library would sync nothing real.
    private func runDropboxSync() async {
        await duplicateRepair?.value
        guard !isPlaceholder else { return }
        await dropbox.sync(library: { self.library }, version: { self.libraryVersion })
    }

    /// Whether a save hasn't reached Dropbox yet.
    var hasUnsyncedChanges: Bool { dropbox.isConnected && !isInMemory && !isPlaceholder && libraryVersion != dropbox.syncedVersion }

    /// Syncs before the app quits, waiting at most `timeout`: an edit made just before quitting otherwise waited
    /// for the next launch to reach other devices.
    func syncBeforeQuit(timeout: Duration = .seconds(5)) async {
        dropboxDelay?.cancel()
        let sync = Task {
            // A sync already running would only queue another pass and return at once.
            await dropbox.waitForSync()
            if hasUnsyncedChanges, !Task.isCancelled { await runDropboxSync() }
        }
        let deadline = Task {
            try? await Task.sleep(for: timeout)
            sync.cancel()
        }
        await sync.value
        deadline.cancel()
    }

    /// Syncs when the app comes to the front (at most once a minute) and before it goes to the background
    /// if there are unsynced changes.
    func syncWithDropbox(for phase: ScenePhase) {
        switch phase {
        case .active:
            // Both couldn't be read if the app was launched before the iPhone's first unlock.
            if isPlaceholder { SharedLibrary.openIfUnlocked() }
            if secretsUnread { loadSecrets() }
            if libraryVersion != dropbox.syncedVersion || dropbox.lastSynced.map({ Date.now.timeIntervalSince($0) > 60 }) ?? true {
                syncWithDropbox()
            }
        case .background where libraryVersion != dropbox.syncedVersion:
            #if os(iOS)
            // Without a background task, iOS suspends the app mid-upload and the edits wait for the next launch.
            dropbox.checkConnectionIfNeeded()
            guard dropbox.isConnected, !isInMemory, backgroundSync == .invalid else { return }
            dropboxDelay?.cancel()
            backgroundSync = UIApplication.shared.beginBackgroundTask(withName: "Dropbox Sync") { [weak self] in
                self?.endBackgroundSync()
            }
            Task {
                // A sync already running would only queue another pass and return at once, ending the
                // background task while that sync was still uploading.
                await dropbox.waitForSync()
                if hasUnsyncedChanges, backgroundSync != .invalid { await runDropboxSync() }
                endBackgroundSync()
            }
            #else
            syncWithDropbox()
            #endif
        default:
            break
        }
    }

    #if os(iOS)
    private func endBackgroundRefresh() {
        guard backgroundRefresh != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundRefresh)
        backgroundRefresh = .invalid
    }

    /// Identifies the background app refresh in Info.plist (`BGTaskSchedulerPermittedIdentifiers`).
    static let backgroundRefreshID = "com.mehdi.towatchdb.refresh"

    /// Asks iOS for a background app refresh in a few hours, when it sees fit. A new request replaces the last.
    func scheduleBackgroundRefresh() {
        guard !isInMemory else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundRefreshID)
        request.earliestBeginDate = .now.addingTimeInterval(3 * 3600)
        do { try BGTaskScheduler.shared.submit(request) } catch {
            Log.refresh.error("Couldn't schedule a background refresh: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The background app refresh: new episodes, then other devices' edits, so Up Next and Upcoming are current when
    /// the app opens. Cancelled when iOS ends it; what was refreshed by then is saved.
    func refreshInBackground() async {
        scheduleBackgroundRefresh()
        SharedLibrary.openIfUnlocked()
        await refreshLibrary()
        dropbox.checkConnectionIfNeeded()
        guard dropbox.isConnected, !isInMemory, !Task.isCancelled else { return }
        await dropbox.waitForSync()
        await runDropboxSync()
    }

    private func endBackgroundSync() {
        guard backgroundSync != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundSync)
        backgroundSync = .invalid
    }
    #endif

    /// Refreshes when the app comes back to the front, at most hourly (on Mac, that's every app switch): titles
    /// otherwise refreshed only at launch, so an app left running for days never got new episodes. Not before
    /// launch's own refresh, which this ran twice.
    func refreshLibraryIfDue() async {
        guard let lastRefresh, Date.now.timeIntervalSince(lastRefresh) > 3600 else { return }
        await refreshLibrary()
    }

    /// Picks up new episodes and release-date changes. `force` ignores the 12-hour freshness window.
    func refreshLibrary(force: Bool = false) async {
        // Not the placeholder: `lastRefresh` would put off refreshing the real library for an hour.
        guard client != nil, !isRefreshing, !isPlaceholder else { return }
        isRefreshing = true
        lastRefresh = .now
        #if os(iOS)
        // Opening the app and leaving within seconds is the common case: without a background task, iOS suspended
        // the refresh with its downloads in flight, and the titles they were for stayed stale.
        backgroundRefresh = UIApplication.shared.beginBackgroundTask(withName: "Library Refresh") { [weak self] in
            self?.endBackgroundRefresh()
        }
        #endif
        defer {
            isRefreshing = false
            #if os(iOS)
            endBackgroundRefresh()
            #endif
            if syncsAfterRefresh {
                syncsAfterRefresh = false
                syncWithDropbox()
            }
        }
        // Same as a sync starting during a refresh, the other way around (both start at launch).
        await duplicateRepair?.value
        await dropbox.waitForSync()
        do {
            let outcome = try await library.refreshStale(maxAge: force ? 0 : 12 * 3600)
            // Cut off (offline, or suspended anyway): the next activation tries again rather than an hour later.
            if outcome.unreachable > 0 { lastRefresh = .distantPast }
        } catch {
            // Said once per launch: the refresh runs again at every activation, and the token stays wrong until
            // it's changed in Settings.
            if !hasReportedRejectedToken {
                hasReportedRejectedToken = true
                errorMessage = "TMDB turned down the access token, so the library couldn't be refreshed. Check the token in Settings. (\(error.localizedDescription))"
            }
        }
        await library.refreshStaleIMDbRatings(maxAge: force ? 0 : 3 * 86400, importedMaxAge: force ? 0 : 7 * 86400)
    }
}

/// The on-disk library, shared by the app's UI and Siri/Shortcuts actions. Actions run in the app's process,
/// so using the same container (and main context) makes their changes appear in open windows immediately.
@MainActor
enum SharedLibrary {
    #if DEBUG
    /// Sample-data runs use a throwaway library, and Siri actions use it too: they changed the real one on disk.
    static let isInMemory = DebugTools.usesSampleData
    #else
    static let isInMemory = false
    #endif
    /// The library on disk, or an empty in-memory placeholder while the store can't be read yet (an iPhone launched
    /// in the background before its first unlock) until `openIfUnlocked` replaces it.
    private(set) static var container = makeContainer(inMemory: isInMemory)
    private static var placeholder: ModelContainer?

    /// Whether `container` is the placeholder. Nothing may be written to it: it's thrown away.
    static var isPlaceholder: Bool { container === placeholder }

    /// Opens the library on disk in place of the placeholder, once the device is unlocked, and tells the app.
    /// Returns whether the library on disk is open.
    @discardableResult
    static func openIfUnlocked() -> Bool {
        guard isPlaceholder else { return true }
        #if os(iOS)
        guard UIApplication.shared.isProtectedDataAvailable else { return false }
        #endif
        guard let opened = openContainer(inMemory: false) else { return false }
        opened.mainContext.autosaveEnabled = false
        container = opened
        placeholder = nil
        Log.library.info("Opened the library after the first unlock")
        AppState.shared?.libraryOpened()
        return true
    }

    /// The library for Siri and Shortcuts actions, opened now if it couldn't be at launch. Throws while the device
    /// hasn't been unlocked since it started, so an action never answers from the placeholder or writes to it.
    static var unlockedContainer: ModelContainer {
        get throws {
            guard openIfUnlocked() else { throw IntentError.locked }
            return container
        }
    }

    /// Why the library on disk couldn't be opened at launch, for an alert once the app is up.
    private(set) static var openFailure: String?

    static func makeContainer(inMemory: Bool) -> ModelContainer {
        let container: ModelContainer
        if let opened = openContainer(inMemory: inMemory) {
            container = opened
        } else {
            // Crashing instead (as this did) crashed every launch before the first unlock: a Shortcuts automation or
            // Siri after a reboot launches the app in the background. The placeholder stands in until it's unlocked.
            do {
                container = try ModelContainer(for: ToWatchSchema.current, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            } catch {
                fatalError("Couldn't open the library database: \(error)")
            }
            placeholder = container
        }
        // Every change is saved explicitly. Autosave also saved batches (a refresh, a list import) halfway,
        // each save redrawing every page and scheduling a Dropbox sync.
        container.mainContext.autosaveEnabled = false
        return container
    }

    /// Nil on iOS when the store exists but can't be read yet: before the device's first unlock.
    private static func openContainer(inMemory: Bool) -> ModelContainer? {
        let schema = ToWatchSchema.current
        let configuration = ModelConfiguration("ToWatchDB", isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        do {
            return try ModelContainer(for: schema, migrationPlan: ToWatchMigrationPlan.self, configurations: configuration)
        } catch {
            // A store that exists but can't be read yet (an iPhone launched in the background before its first
            // unlock) opens once the device is unlocked: moving it aside would lose it.
            let url = configuration.url
            let isLocked = FileManager.default.fileExists(atPath: url.path()) && (try? FileHandle(forReadingFrom: url)) == nil
            guard !inMemory else { fatalError("Couldn't open the library database: \(error)") }
            if isLocked {
                #if os(iOS)
                Log.library.error("The library can't be read until the device is unlocked; opening it then")
                return nil
                #else
                fatalError("Couldn't open the library database: \(error)")
                #endif
            }
            // Crashing here crashed every launch, with no way back (a schema change without a migration, a
            // downgrade, a damaged file). The store is kept aside and the app starts with an empty library, which
            // a Dropbox sync or a backup fills again.
            let folder = moveAside(url)
            Log.library.fault("The library couldn't be opened and was moved aside: \(error.localizedDescription, privacy: .public)")
            DropboxSync.forgetBase()
            openFailure = "The library couldn't be opened (\(error.localizedDescription)), so an empty one was started."
                + (folder.map { " The old one was moved to “\($0.path())”." } ?? "")
                + " With Dropbox sync on, the library comes back with the next sync."
            if let container = try? ModelContainer(for: schema, migrationPlan: ToWatchMigrationPlan.self,
                                                   configurations: configuration) { return container }
            do {
                return try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            } catch {
                fatalError("Couldn't open the library database: \(error)")
            }
        }
    }

    /// Moves the store and its journal files into a new folder next to it, returning the folder.
    private static func moveAside(_ store: URL) -> URL? {
        let manager = FileManager.default
        let folder = store.deletingLastPathComponent()
            .appending(path: "ToWatchDB Unreadable \(Date.now.ISO8601Format().replacing(":", with: "."))")
        guard (try? manager.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return nil }
        for suffix in ["", "-shm", "-wal"] {
            let file = URL(filePath: store.path() + suffix)
            guard manager.fileExists(atPath: file.path()) else { continue }
            try? manager.moveItem(at: file, to: folder.appending(path: file.lastPathComponent))
        }
        return folder
    }

    /// TMDB client from the saved token and language, for code that runs outside the UI.
    static func makeClient(token: String? = TokenStore.load() ?? TokenStore.bundledToken,
                           language: String = UserDefaults.standard.string(forKey: "tmdbLanguage") ?? "") -> TMDBClient? {
        guard let token else { return nil }
        return TMDBClient(token: token, language: language.isEmpty ? TMDBClient.language(for: .current) : language)
    }

    /// For Siri and Shortcuts actions; throws like `unlockedContainer`.
    static var service: LibraryService {
        get throws {
            LibraryService(context: try unlockedContainer.mainContext, client: makeClient(),
                           imdb: OMDbKeyStore.load().map { IMDbClient(apiKey: $0) })
        }
    }

    static var watchRegion: String {
        UserDefaults.standard.string(forKey: "watchRegion") ?? Locale.current.region?.identifier ?? "US"
    }
}

/// Where a Siri or Shortcuts action asked the app to go.
@Observable @MainActor
final class IntentRouter {
    static let shared = IntentRouter()

    enum Destination: Hashable {
        case tab(AppTab)
        case scope(LibraryScope)
    }

    var destination: Destination?
    var title: TitleReference?
}
