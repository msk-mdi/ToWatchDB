import SwiftData
import SwiftUI
import ToWatchCore

struct RootView: View {
    @Environment(AppState.self) private var appState
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
        #if os(iOS)
        .sheet(isPresented: $appState.isShowingSettings) {
            NavigationStack { SettingsView() }
        }
        .onChange(of: sizeClass, initial: true) { _, newValue in
            // Backlog, Watched, Movies and TV Shows live inside the Library tab on iPhone.
            if newValue == .compact, [.backlog, .watched, .movies, .shows].contains(appState.selectedTab) {
                appState.selectedTab = .all
            }
        }
        #endif
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
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }

    /// iPhone: five tabs; the library scopes collapse into one tab with a scope picker.
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
    }

    /// iOS toolbar button that opens Settings; macOS has a Settings menu item instead.
    func settingsToolbarButton(_ appState: AppState) -> some View {
        #if os(iOS)
        toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Settings", systemImage: "gearshape") { appState.isShowingSettings = true }
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
