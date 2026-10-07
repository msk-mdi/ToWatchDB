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
    let container: ModelContainer

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

    private(set) var tokenOverride: String? = TokenStore.load()

    /// The Seerr server titles are requested on, and how the app signs in to it.
    private(set) var seerrServer: String = UserDefaults.standard.string(forKey: "seerrServer") ?? ""
    private(set) var seerrAuth: SeerrAuth? = SeerrAuthStore.load()
    /// Who the app is signed in to Seerr as, for Settings.
    private(set) var seerrUserName: String? = UserDefaults.standard.string(forKey: "seerrUserName")

    /// Loads Discover's trending lists, unless fresh ones are cached. Here rather than in Discover so the
    /// Mac window's Refresh button can reload them.
    func loadTrending(force: Bool = false) async {
        guard let client, let token else { return }
        if !force, trending?.isFresh(token: token, language: language) == true { return }
        trendingError = nil
        let language = language, started = Date.now
        do {
            async let movies = client.trendingMovies()
            async let shows = client.trendingTVShows()
            let loaded = Trending(movies: try await movies.results.map(MediaSummary.init),
                                  shows: try await shows.results.map(MediaSummary.init),
                                  token: token, language: language, loadedAt: started)
            // Two loads can overlap (the page and the Refresh button, or a token or language change). Keep a
            // result only if it's still for the current settings and no newer one landed meanwhile.
            guard token == self.token, language == self.language,
                  (trending.map { $0.loadedAt <= started } ?? true) else { return }
            trending = loaded
        } catch is CancellationError {
        } catch {
            trendingError = error.localizedDescription
        }
    }

    let dropbox = DropboxSync()
    /// Sample-data and snapshot runs use a throwaway library, which must never reach Dropbox.
    private let isInMemory: Bool
    @ObservationIgnored private var dropboxDelay: Task<Void, Never>?
    #if os(iOS)
    @ObservationIgnored private var backgroundSync: UIBackgroundTaskIdentifier = .invalid
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
        container = inMemory ? SharedLibrary.makeContainer(inMemory: true) : SharedLibrary.container
        saveObserver = NotificationCenter.default.addObserver(
            // No queue: the version must change synchronously with the save, before any view redraws with the
            // new data, or a redraw could store a value computed from stale data under the new version.
            forName: ModelContext.didSave, object: container.mainContext, queue: nil
        ) { [weak self] notification in
            let deleted = notification.userInfo?[ModelContext.NotificationKey.deletedIdentifiers.rawValue]
                as? [PersistentIdentifier]
            MainActor.assumeIsolated {
                guard let self else { return }
                self.libraryVersion += 1
                if deleted?.isEmpty == false {
                    self.lastDeletionVersion = self.libraryVersion
                    // Nothing cached before a deletion is served again, and it may hold the deleted models.
                    self.derivedCache.removeAll()
                }
                // Here rather than in a view: on Mac, edits from a title window, Settings, or Siri with the main
                // window closed weren't synced until it reopened.
                if self.libraryVersion != self.dropbox.syncedVersion { self.syncWithDropbox(after: .seconds(5)) }
            }
        }
        #if os(macOS)
        AppDelegate.appState = self
        #endif
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

    /// Every show's progress, computed once per library version and shared by the pages that need it
    /// (library grids, Next to Watch): a show's progress walks all of its episodes. It fetches every show
    /// itself, so a page whose query is narrower can't cache a partial map.
    func showProgress(allowStale: Bool = false) -> [PersistentIdentifier: ShowProgress] {
        let day = Calendar.current.startOfDay(for: .now)
        return cached("show-progress-\(day)", allowStale: allowStale) {
            let shows = (try? container.mainContext.fetch(FetchDescriptor<TVShow>())) ?? []
            return Dictionary(shows.map { ($0.persistentModelID, $0.progressSummary()) }) { first, _ in first }
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

    var library: LibraryService { LibraryService(context: container.mainContext, client: client, imdb: IMDbClient()) }

    func setTokenOverride(_ token: String?) {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            TokenStore.delete()
            tokenOverride = nil
        } else {
            TokenStore.save(trimmed)
            tokenOverride = trimmed
        }
    }

    /// Seerr client for requesting titles, if a server is set up.
    var seerr: SeerrClient? { seerrAuth.flatMap { SeerrClient(server: seerrServer, auth: $0) } }

    /// Saves a connected Seerr client and who it's signed in as; `nil` forgets the server and sign-in.
    func setSeerr(_ client: SeerrClient?, userName: String? = nil) {
        let defaults = UserDefaults.standard
        if let client {
            defaults.set(client.baseURL.absoluteString, forKey: "seerrServer")
            defaults.set(userName, forKey: "seerrUserName")
            SeerrAuthStore.save(client.auth)
            seerrServer = client.baseURL.absoluteString
            seerrAuth = client.auth
            seerrUserName = userName
        } else {
            defaults.removeObject(forKey: "seerrServer")
            defaults.removeObject(forKey: "seerrUserName")
            SeerrAuthStore.delete()
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
        guard dropbox.isConnected, !isInMemory else { return }
        dropboxDelay?.cancel()
        dropboxDelay = Task {
            if delay > .zero {
                try? await Task.sleep(for: delay)
                // The sync that ran meanwhile may have covered these changes (its own save bumps the version too).
                guard !Task.isCancelled, libraryVersion != dropbox.syncedVersion else { return }
            }
            // Its own task, so a later call's cancel can't interrupt a sync midway.
            Task { await dropbox.sync(library: { self.library }, version: { self.libraryVersion }) }
        }
    }

    /// Whether a save hasn't reached Dropbox yet.
    var hasUnsyncedChanges: Bool { dropbox.isConnected && !isInMemory && libraryVersion != dropbox.syncedVersion }

    /// Syncs before the app quits, waiting at most `timeout`: an edit made just before quitting otherwise waited
    /// for the next launch to reach other devices.
    func syncBeforeQuit(timeout: Duration = .seconds(5)) async {
        dropboxDelay?.cancel()
        let sync = Task {
            // A sync already running would only queue another pass and return at once.
            while dropbox.isSyncing, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
            if hasUnsyncedChanges, !Task.isCancelled {
                await dropbox.sync(library: { self.library }, version: { self.libraryVersion })
            }
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
            if libraryVersion != dropbox.syncedVersion || dropbox.lastSynced.map({ Date.now.timeIntervalSince($0) > 60 }) ?? true {
                syncWithDropbox()
            }
        case .background where libraryVersion != dropbox.syncedVersion:
            #if os(iOS)
            // Without a background task, iOS suspends the app mid-upload and the edits wait for the next launch.
            guard dropbox.isConnected, !isInMemory, backgroundSync == .invalid else { return }
            dropboxDelay?.cancel()
            backgroundSync = UIApplication.shared.beginBackgroundTask(withName: "Dropbox Sync") { [weak self] in
                self?.endBackgroundSync()
            }
            Task {
                await dropbox.sync(library: { self.library }, version: { self.libraryVersion })
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
    private func endBackgroundSync() {
        guard backgroundSync != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundSync)
        backgroundSync = .invalid
    }
    #endif

    /// Picks up new episodes and release-date changes. `force` ignores the 12-hour freshness window.
    func refreshLibrary(force: Bool = false) async {
        guard client != nil, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await library.refreshStale(maxAge: force ? 0 : 12 * 3600)
        await library.refreshStaleIMDbRatings(maxAge: force ? 0 : 3 * 86400, importedMaxAge: force ? 0 : 7 * 86400)
    }
}

/// The on-disk library, shared by the app's UI and Siri/Shortcuts actions. Actions run in the app's process,
/// so using the same container (and main context) makes their changes appear in open windows immediately.
@MainActor
enum SharedLibrary {
    static let container = makeContainer(inMemory: false)

    static func makeContainer(inMemory: Bool) -> ModelContainer {
        do {
            let configuration = ModelConfiguration("ToWatchDB", isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
            return try ModelContainer(for: Schema(ToWatchSchema.models), configurations: configuration)
        } catch {
            fatalError("Couldn't open the library database: \(error)")
        }
    }

    /// TMDB client from the saved token and language, for code that runs outside the UI.
    static func makeClient(token: String? = TokenStore.load() ?? TokenStore.bundledToken,
                           language: String = UserDefaults.standard.string(forKey: "tmdbLanguage") ?? "") -> TMDBClient? {
        guard let token else { return nil }
        return TMDBClient(token: token, language: language.isEmpty ? TMDBClient.language(for: .current) : language)
    }

    static var service: LibraryService { LibraryService(context: container.mainContext, client: makeClient(), imdb: IMDbClient()) }

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
