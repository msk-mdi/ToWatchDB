import SwiftData
import SwiftUI
import ToWatchCore

/// Searches TMDB for movies or TV shows.
struct SearchView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.isActivePage) private var isActive

    @State private var query = ""
    @State private var kind: MediaSummary.Kind = .movie
    @State private var results: [MediaSummary] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        // Rebuilt once per save, not on every keystroke.
        let ids = appState.libraryIDs(allowStale: !isActive)
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
        // Again once a token is added (the page said "No Results" until the query changed) or the language changes.
        .task(id: [kind.rawValue, trimmedQuery, appState.token ?? "", appState.language]) { await search() }
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
            searchError = nil
            isSearching = false
            return
        }
        // Searching from the keystroke on: set after the debounce, "No Results" showed while it ran.
        isSearching = true
        searchError = nil
        // Debounce: a newer keystroke cancels this task during the sleep.
        do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
        // A cancelled search leaves it to the newer one, which is searching already.
        defer { if !Task.isCancelled { isSearching = false } }
        do {
            let found = switch kind {
            case .movie: try await client.searchMovies(text).results.map(MediaSummary.init)
            case .tv: try await client.searchTVShows(text).results.map(MediaSummary.init)
            }
            // A newer query or a cleared field cancelled this one after the response came in.
            guard !Task.isCancelled else { return }
            results = found
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
