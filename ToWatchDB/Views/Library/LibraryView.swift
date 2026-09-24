import SwiftData
import SwiftUI
import ToWatchCore

/// Poster grid of library items for a scope, with status filter, sort, and local search.
struct LibraryView: View {
    @Environment(AppState.self) private var appState
    @Query private var movies: [Movie]
    @Query private var shows: [TVShow]

    @State private var scope: LibraryScope
    /// iPhone shows one Library tab with a scope picker instead of separate sidebar entries.
    let allowsScopeChange: Bool
    @State private var statusFilter: WatchStatus?
    @State private var sort: LibrarySort
    @State private var searchText = ""
    @State private var isDropTargeted = false

    init(scope: LibraryScope, allowsScopeChange: Bool = false) {
        _scope = State(initialValue: scope)
        self.allowsScopeChange = allowsScopeChange
        _sort = State(initialValue: scope.defaultSort)
    }

    var body: some View {
        let items = filteredItems
        ScrollView {
            if allowsScopeChange {
                Picker("Show", selection: $scope) {
                    ForEach(LibraryScope.allCases, id: \.self) { Text($0.shortTitle).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
            }
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
        .navigationTitle(allowsScopeChange ? "Library" : scope.title)
        .navigationSubtitleIfAvailable("\(items.count) title\(items.count == 1 ? "" : "s")")
        .searchable(text: $searchText, placement: .adaptiveToolbar, prompt: "Filter \(scope.title.lowercased())")
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Filter and Sort", systemImage: statusFilter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill") {
                    statusPicker
                    sortPicker
                }
            }
            #else
            ToolbarItemGroup {
                statusPicker.pickerStyle(.menu).fixedSize()
                sortPicker.pickerStyle(.menu).fixedSize()
            }
            #endif
        }
        .dropDestination(for: TitleReference.self) { references, _ in
            guard scope.acceptsDrops else { return false }
            Task { await appState.perform { try await $0.add(references, backlog: scope == .backlog) } }
            return true
        } isTargeted: { isDropTargeted = $0 && scope.acceptsDrops }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: scope) { _, newScope in
            statusFilter = nil
            sort = newScope.defaultSort
        }
        .settingsToolbarButton(appState)
    }

    @ViewBuilder
    private var statusPicker: some View {
        if scope != .watched {
            Picker("Status", selection: $statusFilter) {
                Text("Any Status").tag(WatchStatus?.none)
                Divider()
                ForEach(availableStatuses) { status in
                    Label(status.label, systemImage: status.symbol).tag(Optional(status))
                }
            }
        }
    }

    private var sortPicker: some View {
        Picker("Sort", selection: $sort) {
            ForEach(LibrarySort.allCases) { Text($0.label).tag($0) }
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
        .titleInteractions(item.reference)
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
        OpenInNewWindowButton(reference: item.reference)
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
