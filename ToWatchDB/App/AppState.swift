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

    init(inMemory: Bool = false) {
        container = inMemory ? SharedLibrary.makeContainer(inMemory: true) : SharedLibrary.container
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
