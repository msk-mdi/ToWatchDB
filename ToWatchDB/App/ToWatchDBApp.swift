import SwiftData
import SwiftUI
import ToWatchCore

@main
struct ToWatchDBApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(ThemeColor.appIconKey) private var appIcon: ThemeColor = .coral
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
        WindowGroup(id: AppCommands.mainWindowID) {
            RootView()
                .environment(appState)
                .themed()
                .task {
                    #if DEBUG
                    await DebugTools.runIfRequested(appState)
                    #endif
                    await appState.refreshLibrary()
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    // Teach Siri the current show and movie names for phrases like "Mark Severance watched".
                    if phase == .active { ToWatchShortcuts.updateAppShortcutParameters() }
                }
                .onChange(of: appIcon, initial: true) { _, icon in icon.applyAsAppIcon() }
        }
        .modelContainer(appState.container)
        .commands { AppCommands(appState: appState) }
        #if os(macOS)
        .defaultSize(width: 1200, height: 800)
        #endif

        // A single title in its own window ("Open in New Window" on iPad and Mac).
        WindowGroup("Title", for: TitleReference.self) { $reference in
            TitleWindow(reference: reference)
                .environment(appState)
                .themed()
        }
        .modelContainer(appState.container)
        #if os(macOS)
        .defaultSize(width: 900, height: 900)
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(appState)
                .themed()
                .modelContainer(appState.container)
        }
        #endif
    }
}

/// The movie or show on screen in the focused window, for the Title menu.
enum FocusedTitle {
    case movie(Movie)
    case show(TVShow)
}

extension FocusedValues {
    @Entry var focusedTitle: FocusedTitle?
}

struct AppCommands: Commands {
    static let mainWindowID = "main"

    let appState: AppState
    @FocusedValue(\.focusedTitle) private var title
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        #if os(macOS)
        // Replaces File ▸ New Window, which also claimed ⌘N and so shadowed Search TMDB.
        // There's one main window; title windows open from a poster's context menu.
        CommandGroup(replacing: .newItem) { fileCommands }
        CommandGroup(before: .windowList) {
            Button("Library Window") { openWindow(id: Self.mainWindowID) }
                .keyboardShortcut("0")
                .disabled(appState.mainWindowCount > 0)
            Divider()
        }
        #else
        CommandGroup(after: .newItem) { fileCommands }
        #endif
        CommandGroup(after: .importExport) {
            Button("Import Backup…") { inMainWindow { appState.fileRequest = .importBackup } }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Export Backup…") { inMainWindow { appState.fileRequest = .exportBackup } }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Export as CSV…") { inMainWindow { appState.fileRequest = .exportCSV } }
        }
        CommandMenu("Library") {
            Button("Refresh Library") { Task { await appState.refreshLibrary(force: true) } }
                .keyboardShortcut("r")
                .disabled(appState.isRefreshing)
            Divider()
            Button("Next to Watch") { show(.nextToWatch) }
                .keyboardShortcut("1")
            Button("Upcoming") { show(.upcoming) }
                .keyboardShortcut("2")
            Button("Backlog") { show(.backlog) }
                .keyboardShortcut("3")
            Button("All Titles") { show(.all) }
                .keyboardShortcut("4")
            Button("Stats") { show(.stats) }
                .keyboardShortcut("5")
        }
        CommandMenu("Title") { titleCommands }
    }

    @ViewBuilder
    private var fileCommands: some View {
        Button("Search TMDB") { show(.search) }
            .keyboardShortcut("n")
        Divider()
        Button("New Space…") { inMainWindow { appState.collectionEditor = .newSpace() } }
        Button("New Smart List…") { inMainWindow { appState.collectionEditor = .newSmartList } }
        Button("New Tag…") { inMainWindow { appState.collectionEditor = .newTag() } }
    }

    private func show(_ tab: AppTab) {
        inMainWindow { appState.selectedTab = tab }
    }

    /// On macOS the app keeps running with its main window closed; reopen it so the command isn't lost.
    private func inMainWindow(_ action: () -> Void) {
        #if os(macOS)
        if appState.mainWindowCount == 0 { openWindow(id: Self.mainWindowID) }
        #endif
        action()
    }

    @ViewBuilder
    private var titleCommands: some View {
        let library = appState.library
        switch title {
        case let .movie(movie):
            Button(movie.isWatched ? "Mark as Not Watched" : "Mark as Watched") { library.setWatched(movie, !movie.isWatched) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!movie.isWatched && !movie.isReleased())
            Button(movie.isInBacklog ? "Remove from Backlog" : "Add to Backlog") { library.setBacklog(movie, !movie.isInBacklog) }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Button(movie.isFavorite ? "Remove from Favorites" : "Add to Favorites") { library.setFavorite(movie, !movie.isFavorite) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Divider()
            Button("Refresh Title") { Task { await appState.perform { try await $0.refresh(movie) } } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        case let .show(show):
            let next = show.nextEpisodeToWatch()
            Button(next.map { "Mark \($0.code) as Watched" } ?? "Mark Next Episode as Watched") {
                if let next { library.setWatched(next, true) }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(next == nil)
            Button(show.isInBacklog ? "Remove from Backlog" : "Add to Backlog") { library.setBacklog(show, !show.isInBacklog) }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Button(show.isFavorite ? "Remove from Favorites" : "Add to Favorites") { library.setFavorite(show, !show.isFavorite) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button(show.isAbandoned ? "Resume Watching" : "Abandon Show") { library.setAbandoned(show, !show.isAbandoned) }
            Divider()
            Button("Refresh Title") { Task { await appState.perform { try await $0.refresh(show) } } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        case nil:
            Text("Open a movie or show to use these commands")
        }
    }
}
