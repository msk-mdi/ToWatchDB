import SwiftData
import SwiftUI
import ToWatchCore

/// Searches TMDB for movies or TV shows.
struct SearchView: View {
    @Environment(AppState.self) private var appState
    @Query private var movies: [Movie]
    @Query private var shows: [TVShow]

    @State private var query = ""
    @State private var kind: MediaSummary.Kind = .movie
    @State private var results: [MediaSummary] = []
    @State private var isSearching = false
    @State private var searchError: String?

    var body: some View {
        let ids = LibraryIDs(movies: movies, shows: shows)
        ScrollView {
            #if os(iOS)
            kindPicker.padding(.horizontal)
            #endif
            if appState.client == nil {
                MissingTokenView()
            } else if let searchError {
                ContentUnavailableView("Search Failed", systemImage: "exclamationmark.magnifyingglass", description: Text(searchError))
            } else if trimmedQuery.isEmpty {
                ContentUnavailableView("Search TMDB", systemImage: "magnifyingglass",
                                       description: Text("Find movies and TV shows to add to your library."))
            } else if results.isEmpty && !isSearching {
                ContentUnavailableView.search(text: trimmedQuery)
            } else {
                PosterGrid {
                    ForEach(results) { item in
                        RemotePosterCard(summary: item, isInLibrary: ids.contains(item))
                    }
                }
                .padding()
            }
        }
        .navigationTitle("Search")
        .searchable(text: $query, placement: .adaptiveToolbar, prompt: kind == .movie ? "Search movies" : "Search TV shows")
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .principal) { kindPicker.fixedSize() }
            #endif
            if isSearching {
                ToolbarItem { ProgressView().controlSize(.small) }
            }
        }
        .task(id: "\(kind.rawValue):\(trimmedQuery)") { await search() }
    }

    private var kindPicker: some View {
        Picker("Type", selection: $kind) {
            ForEach(MediaSummary.Kind.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func search() async {
        let text = trimmedQuery
        guard let client = appState.client, !text.isEmpty else {
            results = []
            return
        }
        // Debounce: a newer keystroke cancels this task during the sleep.
        do { try await Task.sleep(for: .milliseconds(300)) } catch { return }

        isSearching = true
        searchError = nil
        defer { isSearching = false }
        do {
            switch kind {
            case .movie: results = try await client.searchMovies(text).results.map(MediaSummary.init)
            case .tv: results = try await client.searchTVShows(text).results.map(MediaSummary.init)
            }
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            searchError = error.localizedDescription
        }
    }
}
