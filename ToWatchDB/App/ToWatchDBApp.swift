import SwiftData
import SwiftUI

@main
struct ToWatchDBApp: App {
    #if DEBUG
    // Sample-data and snapshot runs use a throwaway in-memory library.
    @State private var appState = AppState(inMemory: DebugTools.usesSampleData)
    #else
    @State private var appState = AppState()
    #endif

    init() {
        // Posters are requested constantly while scrolling; a larger shared cache keeps them local.
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .task {
                    #if DEBUG
                    await DebugTools.runIfRequested(appState)
                    #endif
                    await appState.refreshLibrary()
                }
        }
        .modelContainer(appState.container)
        .commands { AppCommands(appState: appState) }
        #if os(macOS)
        .defaultSize(width: 1200, height: 800)
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(appState)
                .modelContainer(appState.container)
        }
        #endif
    }
}

struct AppCommands: Commands {
    let appState: AppState

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Search TMDB") { appState.selectedTab = .search }
                .keyboardShortcut("n")
        }
        CommandMenu("Library") {
            Button("Refresh Library") { Task { await appState.refreshLibrary(force: true) } }
                .keyboardShortcut("r")
                .disabled(appState.isRefreshing)
            Divider()
            Button("Next to Watch") { appState.selectedTab = .nextToWatch }
                .keyboardShortcut("1")
            Button("Upcoming") { appState.selectedTab = .upcoming }
                .keyboardShortcut("2")
            Button("Backlog") { appState.selectedTab = .backlog }
                .keyboardShortcut("3")
            Button("All Titles") { appState.selectedTab = .all }
                .keyboardShortcut("4")
        }
    }
}
