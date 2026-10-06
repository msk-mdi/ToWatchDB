import SwiftData
import SwiftUI
import ToWatchCore

/// Trending movies and shows this week.
struct DiscoverView: View {
    @Environment(AppState.self) private var appState
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @Query private var movies: [Movie]
    @Query private var shows: [TVShow]

    @State private var loadError: String?

    private var trendingMovies: [MediaSummary] { appState.trending?.movies ?? [] }
    private var trendingShows: [MediaSummary] { appState.trending?.shows ?? [] }

    var body: some View {
        let ids = appState.cached("library-ids") { LibraryIDs(movies: movies, shows: shows) }
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if appState.client != nil && loadError == nil {
                    shelf("Trending Movies", trendingMovies, ids)
                    shelf("Trending TV Shows", trendingShows, ids)
                }
            }
            .padding()
        }
        .centeredEmptyState(appState.client == nil || loadError != nil) {
            if appState.client == nil {
                MissingTokenView()
            } else {
                ContentUnavailableView {
                    Label("Couldn't Load Trending", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(loadError ?? "")
                } actions: {
                    Button("Retry") { Task { await load(force: true) } }
                }
            }
        }
        .pageTitle("Discover")
        .pageToolbar {
            // Also keeps the Mac toolbar from being empty, which made macOS collapse it and shift the window.
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await load(force: true) } }
                    .disabled(appState.client == nil)
            }
        }
        .settingsToolbarButton(appState)
        .task(id: appState.token) { await load() }
    }

    private func shelf(_ title: String, _ items: [MediaSummary], _ ids: LibraryIDs) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2.bold())
            if items.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(items) { item in
                            RemotePosterCard(summary: item, isInLibrary: ids.contains(item))
                                .frame(width: shelfCardWidth)
                        }
                    }
                    // Room for a poster to grow on hover without being cut off at the top.
                    .padding(.vertical, 8)
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
            }
        }
    }

    private var shelfCardWidth: CGFloat {
        #if os(iOS)
        sizeClass == .compact ? 120 : 150
        #else
        150
        #endif
    }

    private func load(force: Bool = false) async {
        guard let client = appState.client, let token = appState.token else { return }
        if !force, appState.trending?.isFresh(token: token, language: appState.language) == true { return }
        loadError = nil
        do {
            async let movies = client.trendingMovies()
            async let shows = client.trendingTVShows()
            appState.trending = .init(movies: try await movies.results.map(MediaSummary.init),
                                      shows: try await shows.results.map(MediaSummary.init),
                                      token: token, language: appState.language, loadedAt: .now)
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
    }
}

enum TMDBLinks {
    /// Where a TMDB account's API Read Access Token is shown (sign-in required).
    static let apiSettings = URL(string: "https://www.themoviedb.org/settings/api")!
}

struct MissingTokenView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ContentUnavailableView {
            Label("TMDB Token Needed", systemImage: "key")
        } description: {
            Text("ToWatchDB gets movies and shows from TMDB. Create a free account, copy your API Read Access Token, and paste it in Settings.")
        } actions: {
            Link("Get a Token", destination: TMDBLinks.apiSettings)
            #if os(macOS)
            SettingsLink { Text("Open Settings") }
            #else
            Button("Open Settings") { appState.isShowingSettings = true }
            #endif
        }
    }
}
