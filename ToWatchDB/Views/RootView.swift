import SwiftData
import SwiftUI
import ToWatchCore

struct RootView: View {
    @Environment(AppState.self) private var appState
    @AppStorage(NavigationLayout.storageKey) private var layout: NavigationLayout = .sidebar
    @Query(sort: \Space.name) private var spaces: [Space]
    @Query(sort: \SmartList.name) private var smartLists: [SmartList]
    @Query(sort: \MediaTag.name) private var tags: [MediaTag]
    @State private var router = IntentRouter.shared
    /// Tab bar layouts: lists that aren't tabs, opened by a menu command or a Siri or Shortcuts action.
    @State private var intentSheet: IntentSheet?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        @Bindable var appState = appState

        Group {
            if usesTabBar { tabBar } else { sidebar }
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
        .onAppear { appState.mainWindowCount += 1 }
        .onDisappear { appState.mainWindowCount -= 1 }
        .onChange(of: router.destination, initial: true) { _, destination in
            guard let destination else { return }
            router.destination = nil
            switch destination {
            case let .tab(tab): appState.selectedTab = tab
            case let .scope(scope): appState.selectedTab = scope.tab
            }
        }
        .onChange(of: appState.selectedTab, initial: true) { _, tab in
            guard usesTabBar, !tabBarTabs.contains(tab) else { return }
            open(tab)
        }
        .onChange(of: usesTabBar) { _, usesTabBar in
            // Switching layouts: land on the Library tab when the current list has no tab of its own.
            guard usesTabBar, !tabBarTabs.contains(appState.selectedTab) else { return }
            if let scope = appState.selectedTab.libraryScope, LibraryScope.fixed.contains(scope) {
                appState.requestedLibraryScope = scope
            }
            appState.selectedTab = .all
        }
        .sheet(item: $router.title) { reference in
            NavigationStack {
                RemoteDetailView(summary: MediaSummary(reference))
                    .appDestinations()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Done") { router.title = nil } }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 700, minHeight: 700)
            #endif
        }
        .sheet(item: $intentSheet) { sheet in
            NavigationStack {
                Group {
                    switch sheet {
                    case let .scope(scope): LibraryView(scope: scope, showsSettingsButton: false)
                    case .stats: StatsView()
                    case .organize: OrganizeView()
                    }
                }
                .appDestinations()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { intentSheet = nil } }
                }
            }
            #if os(macOS)
            .frame(minWidth: 700, minHeight: 600)
            #endif
        }
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
        #endif
    }

    private enum IntentSheet: Identifiable {
        case scope(LibraryScope), stats, organize
        var id: String { "\(self)" }
    }

    private var isCompact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    /// iPhone always uses tabs; Mac and iPad follow the layout chosen in Settings.
    private var usesTabBar: Bool { isCompact || layout == .topBar }

    /// The tabs in the tab bar. Every other list opens in the Library tab or a sheet.
    private var tabBarTabs: [AppTab] {
        AppTab.hasStatsTab ? [.discover, .nextToWatch, .upcoming, .all, .stats, .search]
            : [.discover, .nextToWatch, .upcoming, .all, .search]
    }

    /// Tab bar layouts: shows a list that isn't a tab, as a Library scope when it is one, otherwise in a sheet.
    private func open(_ tab: AppTab) {
        let scope = tab.libraryScope
        if let scope, LibraryScope.fixed.contains(scope) {
            appState.requestedLibraryScope = scope
        } else if let scope {
            intentSheet = .scope(scope)
        } else if tab == .stats {
            intentSheet = .stats
        } else if tab == .organize {
            intentSheet = .organize
        }
        appState.selectedTab = .all
    }

    private var collectionIDs: Set<UUID> {
        Set(spaces.map(\.uuid) + smartLists.map(\.uuid) + tags.map(\.uuid))
    }

    // MARK: Sidebar

    /// Mac and iPad: every list is its own sidebar entry. The sidebar can't be collapsed.
    private var sidebar: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebarList
                .navigationTitle("ToWatchDB")
                .navigationSplitViewColumnWidth(min: 220, ideal: 230, max: 320)
                .frame(minWidth: 220)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            #if os(macOS)
            PageHost(selected: appState.selectedTab) { tab in screen(for: tab).appDestinations() }
            #else
            // A fresh stack per list, so going back to a list doesn't land on a stale detail page.
            NavigationStack { screen(for: appState.selectedTab).appDestinations() }
                .id(appState.selectedTab)
            #endif
        }
        .navigationSplitViewStyle(.balanced)
    }

    /// iPad uses native list selection. A Mac sidebar would draw its selection in the system accent color
    /// (or the built-in coral), so on Mac the rows draw their own highlight in the chosen color.
    @ViewBuilder
    private var sidebarList: some View {
        #if os(macOS)
        List { sidebarRows }
        #else
        List(selection: Binding(
            get: { appState.selectedTab },
            set: { if let tab = $0 { appState.selectedTab = tab } }
        )) { sidebarRows }
        #endif
    }

    @ViewBuilder
    private var sidebarRows: some View {
        SidebarRow(title: "Discover", symbol: "sparkles.tv", tab: .discover)
        SidebarRow(title: "Search", symbol: "magnifyingglass", tab: .search)

        Section("Lists") {
            SidebarRow(title: "Next to Watch", symbol: "play.circle", tab: .nextToWatch)
            SidebarRow(title: "Upcoming", symbol: "calendar", tab: .upcoming)
            SidebarRow(title: "Backlog", symbol: "tray.full", tab: .backlog)
            SidebarRow(title: "Watched", symbol: "checkmark.circle", tab: .watched)
            SidebarRow(title: "Stats", symbol: "chart.bar.xaxis", tab: .stats)
        }

        Section("Library") {
            SidebarRow(title: "All", symbol: "square.grid.2x2", tab: .all)
            SidebarRow(title: "Movies", symbol: "film", tab: .movies)
            SidebarRow(title: "TV Shows", symbol: "tv", tab: .shows)
            SidebarRow(title: "Organize", symbol: "square.stack.3d.up", tab: .organize)
        }

        if !spaces.isEmpty {
            Section("Spaces") {
                ForEach(spaces) { space in
                    SidebarRow(title: space.name, symbol: space.symbolName, tab: .space(space.uuid), iconColor: space.color)
                }
            }
        }
        if !smartLists.isEmpty {
            Section("Smart Lists") {
                ForEach(smartLists) { list in
                    SidebarRow(title: list.name, symbol: list.symbolName, tab: .smartList(list.uuid), iconColor: list.color)
                }
            }
        }
        if !tags.isEmpty {
            Section("Tags") {
                ForEach(tags) { tag in
                    SidebarRow(title: tag.name, symbol: "tag", tab: .tag(tag.uuid), iconColor: tag.color)
                }
            }
        }
    }

    @ViewBuilder
    private func screen(for tab: AppTab, inTabBar: Bool = false) -> some View {
        switch tab {
        case .discover: DiscoverView()
        case .search: SearchView()
        case .nextToWatch: NextToWatchView()
        case .upcoming: UpcomingView()
        case .stats: StatsView()
        case .organize: OrganizeView()
        default: LibraryView(scope: tab.libraryScope ?? .all, allowsScopeChange: inTabBar)
        }
    }

    // MARK: Tab bar

    /// iPhone, and Mac or iPad with the Top Bar layout. Library scopes collapse into one tab with a
    /// scope picker; collections are chips under it. iOS has no Stats tab (on iPhone a fifth tab would
    /// push Search into "More"; on iPad it would overflow the top bar), so Stats is a chip there too.
    @ViewBuilder
    private var tabBar: some View {
        #if os(macOS)
        // A segmented control in the toolbar's center: unlike TabView's tab bar, it stays in place
        // whatever toolbar items the current screen adds.
        PageHost(selected: appState.selectedTab) { tab in screen(for: tab, inTabBar: true).appDestinations() }
            .toolbar {
                ToolbarItem(placement: .principal) { TopBarPicker(tabs: tabBarTabs) }
            }
        #else
        tabView
        #endif
    }

    private var tabView: some View {
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
            if AppTab.hasStatsTab {
                Tab("Stats", systemImage: "chart.bar.xaxis", value: AppTab.stats) {
                    NavigationStack { StatsView().appDestinations() }
                }
            }
            Tab(value: AppTab.search, role: .search) {
                NavigationStack { SearchView().appDestinations() }
            }
        }
        .tabViewStyle(.tabBarOnly)
    }
}

/// A sidebar entry. On Mac it's a button with its own highlight in the theme color; on iPad, a tagged
/// row for the list's native selection.
private struct SidebarRow: View {
    @Environment(AppState.self) private var appState
    @Environment(\.themeColor) private var themeColor
    let title: String
    let symbol: String
    let tab: AppTab
    /// Spaces, tags, and smart lists keep their own color; built-in lists use the theme color.
    var iconColor: Color?

    var body: some View {
        #if os(macOS)
        let isSelected = appState.selectedTab == tab
        Button { appState.selectedTab = tab } label: {
            Label {
                Text(title).foregroundStyle(isSelected ? Color.white : Color.primary)
            } icon: {
                Image(systemName: symbol).foregroundStyle(isSelected ? Color.white : iconColor ?? themeColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // Select on mouse-down, like a native sidebar; a button alone waits for mouse-up, which felt slow.
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in
            if appState.selectedTab != tab { appState.selectedTab = tab }
        })
        .listRowBackground(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? themeColor : .clear)
                .padding(.horizontal, 10)
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        #else
        // The native selection fills the row with the accent color and turns the text white; the icon has its
        // own color, so it has to turn white too or it vanishes into the highlight (as on Mac).
        let isSelected = appState.selectedTab == tab
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol).foregroundStyle(isSelected ? Color.white : iconColor ?? themeColor)
        }
        .tag(tab)
        #endif
    }
}

#if os(macOS)
/// Mac top bar: the main sections as a segmented control.
private struct TopBarPicker: View {
    @Environment(AppState.self) private var appState
    let tabs: [AppTab]

    var body: some View {
        @Bindable var appState = appState
        Picker("Section", selection: $appState.selectedTab) {
            ForEach(tabs, id: \.self) { tab in
                switch tab {
                case .discover: Text("Discover").tag(tab)
                case .nextToWatch: Text("Next to Watch").tag(tab)
                case .upcoming: Text("Upcoming").tag(tab)
                case .all: Text("Library").tag(tab)
                case .stats: Text("Stats").tag(tab)
                case .search: Image(systemName: "magnifyingglass").accessibilityLabel("Search").tag(tab)
                default: EmptyView()
                }
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}
#endif

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
    /// Whether the tab bar layout has room for a Stats tab (Mac only).
    static var hasStatsTab: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// The library scope this tab shows, if it's a library list.
    var libraryScope: LibraryScope? {
        switch self {
        case .all: .all
        case .movies: .movies
        case .shows: .shows
        case .backlog: .backlog
        case .watched: .watched
        case let .space(id): .space(id)
        case let .tag(id): .tag(id)
        case let .smartList(id): .smartList(id)
        default: nil
        }
    }
}

extension LibraryScope {
    /// The sidebar tab that shows this scope.
    var tab: AppTab {
        switch self {
        case .all: .all
        case .movies: .movies
        case .shows: .shows
        case .backlog: .backlog
        case .watched: .watched
        case let .space(id): .space(id)
        case let .tag(id): .tag(id)
        case let .smartList(id): .smartList(id)
        }
    }
}
