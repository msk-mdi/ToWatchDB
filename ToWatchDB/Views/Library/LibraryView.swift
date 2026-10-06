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
            #if os(macOS)
            // Mac: filters live in the page, not the toolbar. The top bar's section picker never shifts, and a
            // page kept alive offscreen can't leave its search field in the window.
            HStack(spacing: 12) {
                if allowsScopeChange { scopePicker.fixedSize() }
                Spacer()
                statusPicker.pickerStyle(.menu).fixedSize()
                sortPicker.pickerStyle(.menu).fixedSize()
                TextField("Filter", text: $searchText, prompt: Text("Filter \(scope.title.lowercased())"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }
            .labelsHidden()
            .padding(.horizontal)
            .padding(.top, 8)
            if allowsScopeChange { CollectionShortcuts(showsStats: !AppTab.hasStatsTab) }
            #else
            if allowsScopeChange {
                scopePicker.padding(.horizontal)
                CollectionShortcuts(showsStats: !AppTab.hasStatsTab)
            }
            #endif
            if !items.isEmpty {
                // Fetched once here for every card's context menu, instead of two queries per card.
                let menuSpaces = spaces.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                let menuTags = tags.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                PosterGrid {
                    ForEach(items) { item in
                        LibraryPosterCard(item: item, spaces: menuSpaces, tags: menuTags)
                    }
                }
                .padding()
            }
        }
        .centeredEmptyState(items.isEmpty) { emptyState }
        .pageTitle(allowsScopeChange ? "Library" : title)
        .navigationSubtitleIfAvailable("\(items.count) title\(items.count == 1 ? "" : "s")")
        .librarySearch(isEnabled: !hasInlineFilters, text: $searchText, prompt: "Filter \(scope.title.lowercased())")
        .pageToolbar {
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
            if !hasInlineFilters {
                // Menus rather than menu-style pickers: a picker draws its own bezel inside the toolbar's
                // glass capsule, and the two shapes don't line up on hover.
                ToolbarItem {
                    Menu {
                        statusPicker.pickerStyle(.inline)
                    } label: {
                        Text(statusFilter?.label ?? "Any Status")
                    }
                    .help("Filter by status")
                }
                ToolbarItem {
                    Menu {
                        sortPicker.pickerStyle(.inline)
                    } label: {
                        Text(sort.label)
                    }
                    .help("Sort")
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
    private var hasInlineFilters: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    private var scopePicker: some View {
        Picker("Show", selection: $scope) {
            ForEach(LibraryScope.fixed, id: \.self) { Text($0.shortTitle).tag($0) }
        }
        .pickerStyle(.segmented)
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
        return sort.sorted(items)
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
    let spaces: [Space]
    let tags: [MediaTag]
    @State private var confirmDelete = false

    var body: some View {
        // One pass over a show's episodes for the badge, progress bar, caption, and menu.
        let progress: ShowProgress? = if case let .show(show) = item { show.progressSummary() } else { nil }
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

private extension View {
    @ViewBuilder
    func librarySearch(isEnabled: Bool, text: Binding<String>, prompt: String) -> some View {
        if isEnabled {
            searchable(text: text, placement: .adaptiveToolbar, prompt: prompt)
        } else {
            self
        }
    }
}
