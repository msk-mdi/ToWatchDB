import SwiftData
import SwiftUI
import ToWatchCore

/// Poster grid of library items for a scope, with status filter, sort, and local search.
struct LibraryView: View {
    @Environment(AppState.self) private var appState
    @Query private var movies: [Movie]
    @Query private var shows: [TVShow]
    @Query private var spaces: [Space]
    @Query private var tags: [MediaTag]
    @Query private var smartLists: [SmartList]

    @State private var scope: LibraryScope
    /// Tab bar layouts show one Library tab with a scope picker instead of separate sidebar entries.
    let allowsScopeChange: Bool
    /// Pushed collection lists leave Settings to the root screen.
    let showsSettingsButton: Bool
    @State private var statusFilter: WatchStatus?
    @State private var sort: LibrarySort
    @State private var searchText = ""
    @State private var isDropTargeted = false

    init(scope: LibraryScope, allowsScopeChange: Bool = false, showsSettingsButton: Bool = true) {
        _scope = State(initialValue: scope)
        self.allowsScopeChange = allowsScopeChange
        self.showsSettingsButton = showsSettingsButton
        _sort = State(initialValue: scope.defaultSort)
    }

    var body: some View {
        let items = filteredItems
        ScrollView {
            if allowsScopeChange {
                Picker("Show", selection: $scope) {
                    ForEach(LibraryScope.fixed, id: \.self) { Text($0.shortTitle).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                CollectionShortcuts(showsStats: !AppTab.hasStatsTab)
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
        .navigationTitle(allowsScopeChange ? "Library" : title)
        .navigationSubtitleIfAvailable("\(items.count) title\(items.count == 1 ? "" : "s")")
        .searchable(text: $searchText, placement: .adaptiveToolbar, prompt: "Filter \(scope.title.lowercased())")
        .toolbar {
            if let editTarget {
                ToolbarItem {
                    Button("Edit", systemImage: "pencil") { appState.collectionEditor = editTarget }
                }
            }
            #if os(iOS)
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Filter and Sort", systemImage: statusFilter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill") {
                    statusPicker
                    sortPicker
                }
            }
            #else
            // Separate items with their own padding, so each label has room inside its toolbar capsule.
            ToolbarItem {
                statusPicker.pickerStyle(.menu).fixedSize().padding(.horizontal, 8)
            }
            ToolbarItem {
                sortPicker.pickerStyle(.menu).fixedSize().padding(.horizontal, 8)
            }
            #endif
        }
        .dropDestination(for: TitleReference.self) { references, _ in
            guard scope.acceptsDrops else { return false }
            Task {
                await appState.perform { library in
                    try await library.add(references, backlog: scope == .backlog)
                    try await addDropped(references, to: library)
                }
            }
            return true
        } isTargeted: { isDropTargeted = $0 && scope.acceptsDrops }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.tint, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: scope) { _, newScope in
            statusFilter = nil
            sort = newScope.defaultSort
        }
        .onChange(of: appState.requestedLibraryScope, initial: true) { _, requested in
            // A menu command or Siri asked for a list that's a scope of this tab.
            guard allowsScopeChange, let requested, LibraryScope.fixed.contains(requested) else { return }
            scope = requested
            appState.requestedLibraryScope = nil
        }
        .settingsToolbarButton(appState, isVisible: showsSettingsButton)
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

    private var title: String {
        switch scope {
        case let .space(id): spaces.first { $0.uuid == id }?.name ?? "Space"
        case let .tag(id): tags.first { $0.uuid == id }?.name ?? "Tag"
        case let .smartList(id): smartLists.first { $0.uuid == id }?.name ?? "Smart List"
        default: scope.title
        }
    }

    private var editTarget: CollectionEditorTarget? {
        switch scope {
        case let .space(id): spaces.first { $0.uuid == id }.map(CollectionEditorTarget.editSpace)
        case let .tag(id): tags.first { $0.uuid == id }.map(CollectionEditorTarget.editTag)
        case let .smartList(id): smartLists.first { $0.uuid == id }.map(CollectionEditorTarget.editSmartList)
        default: nil
        }
    }

    /// Dropping onto a space or tag also files the title there.
    private func addDropped(_ references: [TitleReference], to library: LibraryService) async throws {
        let space: Space? = if case let .space(id) = scope { library.space(uuid: id) } else { nil }
        let tag: MediaTag? = if case let .tag(id) = scope { library.tag(uuid: id) } else { nil }
        guard space != nil || tag != nil else { return }
        for reference in references {
            let title: LibraryTitle? = switch reference.kind {
            case .movie: library.movie(tmdbID: reference.tmdbID).map(LibraryTitle.movie)
            case .tv: library.show(tmdbID: reference.tmdbID).map(LibraryTitle.show)
            }
            guard let title else { continue }
            if let space, !library.isIn(title, space) { library.toggle(title, in: space) }
            if let tag, !library.isTagged(title, tag) { library.toggle(tag, on: title) }
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
        case let .space(id): items = items.filter { $0.spaces.contains { $0.uuid == id } }
        case let .tag(id): items = items.filter { $0.tags.contains { $0.uuid == id } }
        case let .smartList(id):
            let rules = smartLists.first { $0.uuid == id }?.rules ?? SmartListRules()
            items = items.filter { item in
                switch item {
                case let .movie(movie): rules.matches(movie)
                case let .show(show): rules.matches(show, now: now)
                }
            }
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
            case .space, .tag:
                ContentUnavailableView("Nothing Here Yet", systemImage: "square.stack",
                                       description: Text("Add titles from their page or context menu, or drag posters here."))
            case .smartList:
                ContentUnavailableView("No Matches", systemImage: "wand.and.stars",
                                       description: Text("No titles in your library match this smart list's rules."))
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
        CollectionMenus(title: item.libraryTitle)
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
