import SwiftData
import SwiftUI
import ToWatchCore

struct RootView: View {
    @Environment(AppState.self) private var appState
    @Query(sort: \Space.name) private var spaces: [Space]
    @Query(sort: \SmartList.name) private var smartLists: [SmartList]
    @Query(sort: \MediaTag.name) private var tags: [MediaTag]
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        @Bindable var appState = appState

        Group {
            #if os(iOS)
            if sizeClass == .compact { compactTabs } else { sidebarTabs }
            #else
            sidebarTabs
            #endif
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.errorMessage ?? "")
        }
        .collectionEditorSheet(appState)
        .libraryFileTransfers($appState.fileRequest)
        .onChange(of: collectionIDs) { _, ids in
            // Leave a space, tag, or smart list's tab if it was deleted.
            switch appState.selectedTab {
            case let .space(id), let .tag(id), let .smartList(id):
                if !ids.contains(id) { appState.selectedTab = .all }
            default: break
            }
        }
        #if os(iOS)
        .sheet(isPresented: $appState.isShowingSettings) {
            NavigationStack { SettingsView() }
        }
        .onChange(of: sizeClass, initial: true) { _, newValue in
            // Backlog, Watched, Movies and TV Shows live inside the Library tab on iPhone.
            if newValue == .compact, appState.selectedTab.isSidebarOnly {
                appState.selectedTab = .all
            }
        }
        #endif
    }

    private var collectionIDs: Set<UUID> {
        Set(spaces.map(\.uuid) + smartLists.map(\.uuid) + tags.map(\.uuid))
    }

    /// Mac and iPad: every list is its own sidebar entry.
    private var sidebarTabs: some View {
        @Bindable var appState = appState
        return TabView(selection: $appState.selectedTab) {
            Tab("Discover", systemImage: "sparkles.tv", value: AppTab.discover) {
                NavigationStack { DiscoverView().appDestinations() }
            }
            Tab(value: AppTab.search, role: .search) {
                NavigationStack { SearchView().appDestinations() }
            }

            TabSection("Lists") {
                Tab("Next to Watch", systemImage: "play.circle", value: AppTab.nextToWatch) {
                    NavigationStack { NextToWatchView().appDestinations() }
                }
                Tab("Upcoming", systemImage: "calendar", value: AppTab.upcoming) {
                    NavigationStack { UpcomingView().appDestinations() }
                }
                Tab("Backlog", systemImage: "tray.full", value: AppTab.backlog) {
                    NavigationStack { LibraryView(scope: .backlog).appDestinations() }
                }
                Tab("Watched", systemImage: "checkmark.circle", value: AppTab.watched) {
                    NavigationStack { LibraryView(scope: .watched).appDestinations() }
                }
                Tab("Stats", systemImage: "chart.bar.xaxis", value: AppTab.stats) {
                    NavigationStack { StatsView().appDestinations() }
                }
            }

            TabSection("Library") {
                Tab("All", systemImage: "square.grid.2x2", value: AppTab.all) {
                    NavigationStack { LibraryView(scope: .all).appDestinations() }
                }
                Tab("Movies", systemImage: "film", value: AppTab.movies) {
                    NavigationStack { LibraryView(scope: .movies).appDestinations() }
                }
                Tab("TV Shows", systemImage: "tv", value: AppTab.shows) {
                    NavigationStack { LibraryView(scope: .shows).appDestinations() }
                }
                Tab("Organize", systemImage: "square.stack.3d.up", value: AppTab.organize) {
                    NavigationStack { OrganizeView().appDestinations() }
                }
            }

            if !spaces.isEmpty {
                TabSection("Spaces") {
                    ForEach(spaces) { space in
                        Tab(space.name, systemImage: space.symbolName, value: AppTab.space(space.uuid)) {
                            NavigationStack { LibraryView(scope: .space(space.uuid)).appDestinations() }
                        }
                    }
                }
            }
            if !smartLists.isEmpty {
                TabSection("Smart Lists") {
                    ForEach(smartLists) { list in
                        Tab(list.name, systemImage: list.symbolName, value: AppTab.smartList(list.uuid)) {
                            NavigationStack { LibraryView(scope: .smartList(list.uuid)).appDestinations() }
                        }
                    }
                }
            }
            if !tags.isEmpty {
                TabSection("Tags") {
                    ForEach(tags) { tag in
                        Tab(tag.name, systemImage: "tag", value: AppTab.tag(tag.uuid)) {
                            NavigationStack { LibraryView(scope: .tag(tag.uuid)).appDestinations() }
                        }
                    }
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }

    /// iPhone: four tabs plus Search (a fifth would push Search into "More"). The library scopes
    /// collapse into one tab with a scope picker; Stats and collections are chips under it.
    private var compactTabs: some View {
        @Bindable var appState = appState
        return TabView(selection: $appState.selectedTab) {
            Tab("Discover", systemImage: "sparkles.tv", value: AppTab.discover) {
                NavigationStack { DiscoverView().appDestinations() }
            }
            Tab("Up Next", systemImage: "play.circle", value: AppTab.nextToWatch) {
                NavigationStack { NextToWatchView().appDestinations() }
            }
            Tab("Upcoming", systemImage: "calendar", value: AppTab.upcoming) {
                NavigationStack { UpcomingView().appDestinations() }
            }
            Tab("Library", systemImage: "square.grid.2x2", value: AppTab.all) {
                NavigationStack { LibraryView(scope: .all, allowsScopeChange: true).appDestinations() }
            }
            Tab(value: AppTab.search, role: .search) {
                NavigationStack { SearchView().appDestinations() }
            }
        }
    }
}

extension View {
    /// Registers detail destinations shared by every tab's navigation stack.
    func appDestinations() -> some View {
        navigationDestination(for: Movie.self) { MovieDetailView(movie: $0) }
            .navigationDestination(for: TVShow.self) { TVShowDetailView(show: $0) }
            .navigationDestination(for: MediaSummary.self) { RemoteDetailView(summary: $0) }
            .navigationDestination(for: LibraryScope.self) { LibraryView(scope: $0, showsSettingsButton: false) }
            .navigationDestination(for: OrganizeRoute.self) { _ in OrganizeView() }
            .navigationDestination(for: StatsRoute.self) { _ in StatsView() }
    }

    /// iOS toolbar button that opens Settings; macOS has a Settings menu item instead.
    func settingsToolbarButton(_ appState: AppState, isVisible: Bool = true) -> some View {
        #if os(iOS)
        toolbar {
            if isVisible {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { appState.isShowingSettings = true }
                }
            }
        }
        #else
        self
        #endif
    }
}

extension SearchFieldPlacement {
    /// Toolbar search on macOS; the system default (navigation bar / tab search) on iOS.
    static var adaptiveToolbar: SearchFieldPlacement {
        #if os(macOS)
        .toolbar
        #else
        .automatic
        #endif
    }
}

extension AppTab {
    /// Tabs that exist only in the sidebar layout; iPhone reaches them from the Library tab.
    var isSidebarOnly: Bool {
        switch self {
        case .backlog, .watched, .movies, .shows, .organize, .stats, .space, .tag, .smartList: true
        default: false
        }
    }
}
