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
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        let ids = LibraryIDs(movies: movies, shows: shows)
        ScrollView {
            kindPicker
                #if os(macOS)
                .fixedSize()
                .padding(.top, 8)
                #endif
                .padding(.horizontal)
            if !showsPlaceholder {
                PosterGrid {
                    ForEach(results) { item in
                        RemotePosterCard(summary: item, isInLibrary: ids.contains(item))
                    }
                }
                .padding()
            }
        }
        .centeredEmptyState(showsPlaceholder) { placeholder }
        .pageTitle("Search")
        .modifier(PageSearch(text: $query, prompt: kind == .movie ? "Search movies" : "Search TV shows",
                             isFocused: $isSearchFocused))
        .onChange(of: appState.selectedTab, initial: true) { _, tab in
            // Opening Search (tab, sidebar, or ⌘N) goes straight to typing, keyboard up on iPhone.
            guard tab == .search else { return }
            Task {
                // Let the tab switch settle first, or the focus request can be dropped mid-transition.
                try? await Task.sleep(for: .milliseconds(100))
                isSearchFocused = true
            }
        }
        .pageToolbar {
            if isSearching {
                ToolbarItem { ProgressView().controlSize(.small) }
            }
        }
        .task(id: "\(kind.rawValue):\(trimmedQuery)") { await search() }
    }

    private var showsPlaceholder: Bool {
        appState.client == nil || searchError != nil || trimmedQuery.isEmpty || (results.isEmpty && !isSearching)
    }

    @ViewBuilder
    private var placeholder: some View {
        if appState.client == nil {
            MissingTokenView()
        } else if let searchError {
            ContentUnavailableView("Search Failed", systemImage: "exclamationmark.magnifyingglass", description: Text(searchError))
        } else if trimmedQuery.isEmpty {
            ContentUnavailableView("Search TMDB", systemImage: "magnifyingglass",
                                   description: Text("Find movies and TV shows to add to your library."))
        } else {
            ContentUnavailableView.search(text: trimmedQuery)
        }
    }

    private var kindPicker: some View {
        Picker("Type", selection: $kind) {
            ForEach(MediaSummary.Kind.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
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

/// The search field, on the visible page only: a page kept alive offscreen would otherwise add its own.
private struct PageSearch: ViewModifier {
    @Environment(\.isActivePage) private var isActive
    @Binding var text: String
    let prompt: String
    var isFocused: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        if isActive {
            content
                .searchable(text: $text, placement: .adaptiveToolbar, prompt: prompt)
                .searchFocused(isFocused)
        } else {
            content
        }
    }
}
