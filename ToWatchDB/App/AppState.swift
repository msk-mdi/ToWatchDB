import Foundation
import Observation
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
    @ObservationIgnored private var saveObserver: (any NSObjectProtocol)?

    init(inMemory: Bool = false) {
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
                if deleted?.isEmpty == false { self.lastDeletionVersion = self.libraryVersion }
            }
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
    /// (library grids, Next to Watch): a show's progress walks all of its episodes.
    func progress(of shows: [TVShow], allowStale: Bool = false) -> [PersistentIdentifier: ShowProgress] {
        let day = Calendar.current.startOfDay(for: .now)
        return cached("show-progress-\(day)", allowStale: allowStale) {
            Dictionary(shows.map { ($0.persistentModelID, $0.progressSummary()) }) { first, _ in first }
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

    var library: LibraryService { LibraryService(context: container.mainContext, client: client) }

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

    /// Runs a library operation and surfaces any error as an alert.
    func perform(_ operation: @MainActor (LibraryService) async throws -> Void) async {
        do {
            try await operation(library)
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Picks up new episodes and release-date changes. `force` ignores the 12-hour freshness window.
    func refreshLibrary(force: Bool = false) async {
        guard client != nil, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await library.refreshStale(maxAge: force ? 0 : 12 * 3600)
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
        return TMDBClient(token: token, language: language.isEmpty ? Locale.current.identifier(.bcp47) : language)
    }

    static var service: LibraryService { LibraryService(context: container.mainContext, client: makeClient()) }

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
