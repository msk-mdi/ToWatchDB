import SwiftData
import SwiftUI
import ToWatchCore

/// Poster grid of library items for a scope, with status filter, sort, and local search.
struct LibraryView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.isActivePage) private var isActive
    @Query private var movies: [Movie]
    @Query private var shows: [TVShow]
    // Sorted by the store (localized standard order), not on every body pass.
    @Query(sort: \Space.name) private var spaces: [Space]
    @Query(sort: \MediaTag.name) private var tags: [MediaTag]
    @Query private var smartLists: [SmartList]

    @State private var scope: LibraryScope
    /// Tab bar layouts show one Library tab with a scope picker instead of separate sidebar entries.
    let allowsScopeChange: Bool
    @Environment(\.showsTitleInPage) private var showsTitleInPage
    /// Pushed collection lists leave Settings to the root screen.
    let showsSettingsButton: Bool
    @State private var statusFilter: WatchStatus?
    /// Only titles with this genre. Applied after the cached list, like the text filter.
    @State private var genreFilter: String?
    @State private var sort: LibrarySort
    @State private var searchText = ""
    @State private var isDropTargeted = false

    init(scope: LibraryScope, allowsScopeChange: Bool = false, showsSettingsButton: Bool = true) {
        _scope = State(initialValue: scope)
        self.allowsScopeChange = allowsScopeChange
        self.showsSettingsButton = showsSettingsButton
        _sort = State(initialValue: scope.defaultSort)
        // A list with a fixed scope loads only the titles it can show. With a scope picker the scope can change,
        // so everything is loaded.
        if !allowsScopeChange {
            switch scope {
            case .movies: _shows = Query(filter: #Predicate { _ in false })
            case .shows: _movies = Query(filter: #Predicate { _ in false })
            case .backlog:
                _movies = Query(filter: #Predicate { $0.isInBacklog })
                _shows = Query(filter: #Predicate { $0.isInBacklog })
            case .watched: _movies = Query(filter: #Predicate { $0.isWatched })
            default: break
            }
        }
    }

    var body: some View {
        let progress = appState.showProgress(allowStale: !isActive)
        let scoped = scopedSortedItems(progress)
        // Cached with the list it counts: typing in the filter field redraws the page on every keystroke.
        let genres = appState.cached("library-genres-\(scope)-\(String(describing: statusFilter))", allowStale: !isActive) {
            genreCounts(scoped)
        }
        let items = filtered(scoped)
        ScrollView {
            #if os(macOS)
            if allowsScopeChange {
                // Mac top bar: filters live in the page so the section picker in the toolbar never shifts.
                HStack(spacing: 12) {
                    scopePicker.fixedSize()
                    // The window title and subtitle stay out of the top bar (see RootView), so the count is here.
                    Text("\(items.count) title\(items.count == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    // Pull-down menus rather than menu-style pickers: a picker's menu opens over the button,
                    // shifted so the checked item lines up with it, instead of dropping straight down.
                    // Neutral like the rest of the header, rather than drawn in the accent color.
                    Group {
                        statusMenu
                        genreMenu(genres)
                        sortMenu
                    }
                    .fixedSize()
                    .tint(.primary)
                    filterField.textFieldStyle(.roundedBorder).frame(width: 180)
                }
                .labelsHidden()
                .padding(.horizontal)
                .padding(.top, 8)
                CollectionShortcuts(showsStats: !AppTab.hasStatsTab)
            } else if showsTitleInPage {
                // A space, tag, or smart list pushed from the top bar's chips: the window shows no title.
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(title).font(.title2.bold())
                    Text("\(items.count) title\(items.count == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                }
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal)
                .padding(.top, 8)
            }
            #else
            if allowsScopeChange {
                scopePicker.padding(.horizontal)
                CollectionShortcuts(showsStats: !AppTab.hasStatsTab)
            }
            #endif
            if !items.isEmpty {
                // Fetched once here for every card's context menu, instead of two queries per card.
                let menuSpaces = spaces, menuTags = tags
                PosterGrid {
                    if sort == .genre {
                        // A section per genre; each title appears once, under its main genre.
                        ForEach(genreSections(items), id: \.genre) { section in
                            Section {
                                ForEach(section.items) { item in
                                    LibraryPosterCard(item: item, progress: showProgress(for: item, in: progress),
                                                      spaces: menuSpaces, tags: menuTags)
                                }
                            } header: {
                                GenreHeader(title: section.genre ?? "No Genre", count: section.items.count)
                            }
                        }
                    } else {
                        ForEach(items) { item in
                            LibraryPosterCard(item: item, progress: showProgress(for: item, in: progress),
                                              spaces: menuSpaces, tags: menuTags)
                        }
                    }
                }
                .padding()
            }
        }
        .centeredEmptyState(items.isEmpty) { emptyState }
        .pageTitle(allowsScopeChange ? "Library" : title)
        .navigationSubtitleIfAvailable("\(items.count) title\(items.count == 1 ? "" : "s")")
        #if os(iOS)
        .searchable(text: $searchText, placement: .adaptiveToolbar, prompt: "Filter \(scope.title.lowercased())")
        #endif
        .pageToolbar {
            if let editTarget {
                ToolbarItem {
                    Button("Edit", systemImage: "pencil") { appState.collectionEditor = editTarget }
                }
            }
            #if os(iOS)
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Filter and Sort", systemImage: statusFilter == nil && genreFilter == nil
                     ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill") {
                    statusPicker
                    Menu {
                        genrePicker(genres).pickerStyle(.inline)
                    } label: {
                        Label(genreFilter ?? "Any Genre", systemImage: "theatermasks")
                    }
                    sortPicker
                }
            }
            #else
            if !hasInlineFilters {
                // Menus rather than menu-style pickers: a picker draws its own bezel inside the toolbar's
                // glass capsule, and the two shapes don't line up on hover.
                // Everything in Watched is watched, so there's no status to filter by there.
                if scope != .watched {
                    ToolbarItem { statusMenu }
                }
                ToolbarItem { genreMenu(genres) }
                ToolbarItem { sortMenu }
                // A plain field rather than `.searchable`: only the visible page adds it (see PageHost), and
                // the toolbar never ends up empty, which made macOS collapse it and shift the whole window.
                ToolbarItem {
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        filterField.textFieldStyle(.plain)
                        if !searchText.isEmpty {
                            Button("Clear", systemImage: "xmark.circle.fill") { searchText = "" }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(width: 220)
                }
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
            genreFilter = nil
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

    /// Mac top bar: the filters sit in the page header instead of the toolbar.
    /// Mac: the filters are in the toolbar in the sidebar layout, in the page in the top bar layout.
    /// Either way they're not `.searchable`, which a page kept alive offscreen couldn't switch off.
    private var hasInlineFilters: Bool {
        #if os(macOS)
        allowsScopeChange
        #else
        false
        #endif
    }

    private var filterField: some View {
        TextField("Filter", text: $searchText, prompt: Text("Filter \(scope.title.lowercased())"))
            .labelsHidden()
    }

    private var scopePicker: some View {
        Picker("Show", selection: $scope) {
            ForEach(LibraryScope.fixed, id: \.self) { Text($0.shortTitle).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    #if os(macOS)
    @ViewBuilder
    private var statusMenu: some View {
        if scope != .watched {
            Menu {
                statusPicker.pickerStyle(.inline)
            } label: {
                Text(statusFilter?.label ?? "Any Status")
            }
            .help("Filter by status")
        }
    }

    private func genreMenu(_ genres: [(name: String, count: Int)]) -> some View {
        Menu {
            genrePicker(genres).pickerStyle(.inline)
        } label: {
            Text(genreFilter ?? "Any Genre")
        }
        .help("Filter by genre")
    }

    private var sortMenu: some View {
        Menu {
            sortPicker.pickerStyle(.inline)
        } label: {
            Text(sort.label)
        }
        .help("Sort")
    }
    #endif

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

    /// Genres in the current list with how many titles have each, plus the selected one even if it's gone.
    private func genrePicker(_ genres: [(name: String, count: Int)]) -> some View {
        Picker("Genre", selection: $genreFilter) {
            Text("Any Genre").tag(String?.none)
            Divider()
            if let genreFilter, !genres.contains(where: { $0.name == genreFilter }) {
                Text(genreFilter).tag(Optional(genreFilter))
            }
            ForEach(genres, id: \.name) { genre in
                Text("\(genre.name) (\(genre.count))").tag(Optional(genre.name))
            }
        }
    }

    private func genreCounts(_ items: [LibraryItem]) -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for item in items {
            for genre in Set(item.genres) { counts[genre, default: 0] += 1 }
        }
        return counts.map { (name: $0.key, count: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Consecutive runs of the same main genre; the list is already sorted by genre.
    private func genreSections(_ items: [LibraryItem]) -> [(genre: String?, items: [LibraryItem])] {
        var sections: [(genre: String?, items: [LibraryItem])] = []
        for item in items {
            if let last = sections.indices.last, sections[last].genre == item.primaryGenre {
                sections[last].items.append(item)
            } else {
                sections.append((item.primaryGenre, [item]))
            }
        }
        return sections
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

    /// Scoped, status-filtered, and sorted items, cached per library version: a show's status and last-watched
    /// date walk its episodes, so they come from the shared progress map. A hidden page keeps its last list.
    private func scopedSortedItems(_ progress: [PersistentIdentifier: ShowProgress]) -> [LibraryItem] {
        let key = "library-\(scope)-\(sort)-\(String(describing: statusFilter))"
        return appState.cached(key, allowStale: !isActive) { scopedItems(progress) }
    }

    /// The genre and text filters run on the cached list, so they only match genres and titles.
    private func filtered(_ items: [LibraryItem]) -> [LibraryItem] {
        var items = items
        if let genreFilter { items = items.filter { $0.genres.contains(genreFilter) } }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty { items = items.filter { $0.title.localizedStandardContains(query) } }
        return items
    }

    private func showProgress(for item: LibraryItem, in progress: [PersistentIdentifier: ShowProgress]) -> ShowProgress? {
        guard case let .show(show) = item else { return nil }
        return progress[show.persistentModelID] ?? show.progressSummary()
    }

    private func scopedItems(_ progress: [PersistentIdentifier: ShowProgress]) -> [LibraryItem] {
        func status(_ item: LibraryItem) -> WatchStatus {
            self.showProgress(for: item, in: progress)?.status ?? item.watchStatus()
        }
        var items: [LibraryItem] = switch scope {
        case .movies: movies.map(LibraryItem.movie)
        case .shows: shows.map(LibraryItem.show)
        default: movies.map(LibraryItem.movie) + shows.map(LibraryItem.show)
        }
        switch scope {
        case .backlog: items = items.filter(\.isInBacklog)
        case .watched: items = items.filter { status($0) == .watched }
        case let .space(id): items = items.filter { $0.spaces.contains { $0.uuid == id } }
        case let .tag(id): items = items.filter { $0.tags.contains { $0.uuid == id } }
        case let .smartList(id):
            let rules = smartLists.first { $0.uuid == id }?.rules ?? SmartListRules()
            items = items.filter { item in
                switch item {
                case let .movie(movie): rules.matches(movie)
                case let .show(show): rules.matches(show, status: progress[show.persistentModelID]?.status)
                }
            }
        default: break
        }
        if let statusFilter {
            items = items.filter { status($0) == statusFilter }
        }
        return sort.sorted(items) { self.showProgress(for: $0, in: progress)?.lastWatched ?? $0.lastWatched }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !searchText.isEmpty || statusFilter != nil || genreFilter != nil {
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

/// Section title when the grid is sorted by genre.
private struct GenreHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.bold())
            Text(count.formatted()).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.top, 8)
    }
}

/// Library poster with status badge, progress, and quick actions.
struct LibraryPosterCard: View {
    @Environment(AppState.self) private var appState
    let item: LibraryItem
    /// A show's progress, computed by the grid (it walks the show's episodes).
    let progress: ShowProgress?
    let spaces: [Space]
    let tags: [MediaTag]
    @State private var confirmDelete = false

    var body: some View {
        let status = progress?.status ?? item.watchStatus()
        Group {
            switch item {
            case let .movie(movie): NavigationLink(value: movie) { card(status: status, progress: progress) }
            case let .show(show): NavigationLink(value: show) { card(status: status, progress: progress) }
            }
        }
        .buttonStyle(.plain)
        .titleInteractions(item.reference)
        .contextMenu { menu(next: progress?.nextEpisode) }
        .confirmationDialog("Remove “\(item.title)” from your library?", isPresented: $confirmDelete) {
            Button("Remove", role: .destructive) {
                switch item {
                case let .movie(movie): appState.library.delete(movie)
                case let .show(show): appState.library.delete(show)
                }
            }
        }
    }

    private func card(status: WatchStatus, progress: ShowProgress?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            PosterImage(path: item.posterPath)
                .overlay(alignment: .topTrailing) { StatusBadge(status: status).padding(6) }
                .overlay(alignment: .topLeading) {
                    if let rating = item.imdbRating { IMDbBadge(rating: rating).padding(6) }
                }
                .overlay(alignment: .bottom) {
                    if let progress, status == .watching {
                        ProgressView(value: progress.fraction)
                            .tint(.orange)
                            .padding(8)
                    }
                }
            Text(item.title)
                .font(.callout.weight(.medium))
                .lineLimit(2, reservesSpace: true)
            Text(caption(next: progress?.nextEpisode))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(.rect)
    }

    private func caption(next: Episode?) -> String {
        switch item {
        case let .movie(movie):
            return movie.releaseDate?.yearString ?? "Movie"
        case let .show(show):
            if let next { return "Next: \(next.code)" }
            return show.firstAirDate?.yearString ?? "TV Show"
        }
    }

    @ViewBuilder
    private func menu(next: Episode?) -> some View {
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
            if let next {
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
        CollectionMenus(title: item.libraryTitle, spaces: spaces, tags: tags)
        OpenInNewWindowButton(reference: item.reference)
        Button("Remove from Library…", systemImage: "trash", role: .destructive) { confirmDelete = true }
    }
}

extension View {
    /// macOS window subtitle, set by the visible page only (see `PageHost`).
    @ViewBuilder
    func navigationSubtitleIfAvailable(_ subtitle: String) -> some View {
        #if os(macOS)
        modifier(PageSubtitle(subtitle: subtitle))
        #else
        self
        #endif
    }
}

#if os(macOS)
private struct PageSubtitle: ViewModifier {
    @Environment(\.isActivePage) private var isActive
    let subtitle: String

    func body(content: Content) -> some View {
        content.background {
            if isActive { Color.clear.navigationSubtitle(subtitle) }
        }
    }
}
#endif
