import SwiftData
import SwiftUI
import ToWatchCore

/// Poster grid of library items for a scope, with status filter, sort, and local search.
struct LibraryView: View {
    @Environment(AppState.self) private var appState
    @Query private var movies: [Movie]
    @Query private var shows: [TVShow]

    let scope: LibraryScope
    @State private var statusFilter: WatchStatus?
    @State private var sort: LibrarySort
    @State private var searchText = ""

    init(scope: LibraryScope) {
        self.scope = scope
        _sort = State(initialValue: scope == .watched ? .lastWatched : .added)
    }

    var body: some View {
        let items = filteredItems
        ScrollView {
            if items.isEmpty {
                emptyState
            } else {
                PosterGrid {
                    ForEach(items) { item in
                        LibraryPosterCard(item: item)
                    }
                }
                .padding()
            }
        }
        .navigationTitle(scope.title)
        .navigationSubtitleIfAvailable("\(items.count) title\(items.count == 1 ? "" : "s")")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Filter \(scope.title.lowercased())")
        .toolbar {
            ToolbarItemGroup {
                if scope != .watched {
                    Picker("Status", selection: $statusFilter) {
                        Text("Any Status").tag(WatchStatus?.none)
                        Divider()
                        ForEach(availableStatuses) { status in
                            Label(status.label, systemImage: status.symbol).tag(Optional(status))
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                Picker("Sort", selection: $sort) {
                    ForEach(LibrarySort.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
    }

    private var availableStatuses: [WatchStatus] {
        scope == .movies ? [.notWatched, .watched] : WatchStatus.allCases
    }

    private var filteredItems: [LibraryItem] {
        let now = Date.now
        var items: [LibraryItem] = switch scope {
        case .movies: movies.map(LibraryItem.movie)
        case .shows: shows.map(LibraryItem.show)
        default: movies.map(LibraryItem.movie) + shows.map(LibraryItem.show)
        }
        switch scope {
        case .backlog: items = items.filter(\.isInBacklog)
        case .watched: items = items.filter { $0.watchStatus(asOf: now) == .watched }
        default: break
        }
        if let statusFilter {
            items = items.filter { $0.watchStatus(asOf: now) == statusFilter }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            items = items.filter { $0.title.localizedStandardContains(query) }
        }
        return items.sorted(by: sort.areInOrder)
    }

    @ViewBuilder
    private var emptyState: some View {
        if !searchText.isEmpty || statusFilter != nil {
            ContentUnavailableView("No Matches", systemImage: "line.3.horizontal.decrease.circle",
                                   description: Text("Try a different filter."))
        } else {
            switch scope {
            case .backlog:
                ContentUnavailableView("Backlog Is Empty", systemImage: "tray",
                                       description: Text("Add titles you want to get to eventually."))
            case .watched:
                ContentUnavailableView("Nothing Watched Yet", systemImage: "checkmark.circle",
                                       description: Text("Titles you finish appear here."))
            default:
                ContentUnavailableView {
                    Label("Your Library Is Empty", systemImage: "film.stack")
                } description: {
                    Text("Search TMDB to add movies and TV shows.")
                } actions: {
                    Button("Search TMDB") { appState.selectedTab = .search }
                }
            }
        }
    }
}

/// Library poster with status badge, progress, and quick actions.
struct LibraryPosterCard: View {
    @Environment(AppState.self) private var appState
    let item: LibraryItem
    @State private var confirmDelete = false

    var body: some View {
        let status = item.watchStatus()
        Group {
            switch item {
            case let .movie(movie): NavigationLink(value: movie) { card(status: status) }
            case let .show(show): NavigationLink(value: show) { card(status: status) }
            }
        }
        .buttonStyle(.plain)
        .contextMenu { menu(status: status) }
        .confirmationDialog("Remove “\(item.title)” from your library?", isPresented: $confirmDelete) {
            Button("Remove", role: .destructive) {
                switch item {
                case let .movie(movie): appState.library.delete(movie)
                case let .show(show): appState.library.delete(show)
                }
            }
        }
    }

    private func card(status: WatchStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            PosterImage(path: item.posterPath)
                .overlay(alignment: .topTrailing) { StatusBadge(status: status).padding(6) }
                .overlay(alignment: .bottom) {
                    if case let .show(show) = item, status == .watching {
                        ProgressView(value: show.progress())
                            .tint(.orange)
                            .padding(8)
                    }
                }
            Text(item.title)
                .font(.callout.weight(.medium))
                .lineLimit(2, reservesSpace: true)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(.rect)
    }

    private var caption: String {
        switch item {
        case let .movie(movie):
            return movie.releaseDate?.yearString ?? "Movie"
        case let .show(show):
            if let next = show.nextEpisodeToWatch() { return "Next: \(next.code)" }
            return show.firstAirDate?.yearString ?? "TV Show"
        }
    }

    @ViewBuilder
    private func menu(status: WatchStatus) -> some View {
        let library = appState.library
        switch item {
        case let .movie(movie):
            Button(movie.isWatched ? "Mark as Not Watched" : "Mark as Watched",
                   systemImage: movie.isWatched ? "circle" : "checkmark.circle") {
                library.setWatched(movie, !movie.isWatched)
            }
            .disabled(!movie.isWatched && !movie.isReleased())
            Button(movie.isInBacklog ? "Remove from Backlog" : "Move to Backlog", systemImage: "tray.full") {
                library.setBacklog(movie, !movie.isInBacklog)
            }
        case let .show(show):
            if let next = show.nextEpisodeToWatch() {
                Button("Mark \(next.code) as Watched", systemImage: "checkmark.circle") { library.setWatched(next, true) }
            }
            Button(show.isInBacklog ? "Remove from Backlog" : "Move to Backlog", systemImage: "tray.full") {
                library.setBacklog(show, !show.isInBacklog)
            }
            Button(show.isAbandoned ? "Resume Watching" : "Abandon", systemImage: "xmark.circle") {
                library.setAbandoned(show, !show.isAbandoned)
            }
        }
        Divider()
        Button("Remove from Library…", systemImage: "trash", role: .destructive) { confirmDelete = true }
    }
}

extension View {
    @ViewBuilder
    func navigationSubtitleIfAvailable(_ subtitle: String) -> some View {
        #if os(macOS)
        navigationSubtitle(subtitle)
        #else
        self
        #endif
    }
}
