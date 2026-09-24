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

    @State private var trendingMovies: [MediaSummary] = []
    @State private var trendingShows: [MediaSummary] = []
    @State private var loadError: String?

    var body: some View {
        let ids = LibraryIDs(movies: movies, shows: shows)
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if appState.client == nil {
                    MissingTokenView()
                } else if let loadError {
                    ContentUnavailableView {
                        Label("Couldn't Load Trending", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button("Retry") { Task { await load() } }
                    }
                } else {
                    shelf("Trending Movies", trendingMovies, ids)
                    shelf("Trending TV Shows", trendingShows, ids)
                }
            }
            .padding()
        }
        .navigationTitle("Discover")
        .settingsToolbarButton(appState)
        .task(id: appState.token) { await load() }
    }

    private func shelf(_ title: String, _ items: [MediaSummary], _ ids: LibraryIDs) -> some View {
        VStack(alignment: .leading, spacing: 12) {
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
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.hidden)
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

    private func load() async {
        guard let client = appState.client else { return }
        loadError = nil
        do {
            async let movies = client.trendingMovies()
            async let shows = client.trendingTVShows()
            trendingMovies = try await movies.results.map(MediaSummary.init)
            trendingShows = try await shows.results.map(MediaSummary.init)
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
    }
}

struct MissingTokenView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ContentUnavailableView {
            Label("TMDB Token Needed", systemImage: "key")
        } description: {
            Text("Add your TMDB read access token in Settings to search and discover titles.")
        } actions: {
            #if os(macOS)
            SettingsLink { Text("Open Settings") }
            #else
            Button("Open Settings") { appState.isShowingSettings = true }
            #endif
        }
    }
}
