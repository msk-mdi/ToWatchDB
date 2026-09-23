import SwiftData
import SwiftUI
import ToWatchCore

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        TabView(selection: $appState.selectedTab) {
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
        .alert("Something went wrong", isPresented: Binding(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.errorMessage ?? "")
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
}
