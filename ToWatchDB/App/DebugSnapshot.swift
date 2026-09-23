#if DEBUG && os(macOS)
import AppKit
import SwiftUI
import ToWatchCore

/// Debug-only visual check: launch with `-UISnapshotDir <dir>` to seed sample titles, visit each tab,
/// and write a PNG of the window per tab (the app captures itself, so no screen-recording permission is needed).
@MainActor
enum DebugSnapshot {
    static func runIfRequested(_ appState: AppState) async {
        guard let dir = UserDefaults.standard.string(forKey: "UISnapshotDir") else { return }
        let output = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        await appState.perform { library in
            let severance = try await library.addShow(tmdbID: 95396)
            if let s1 = severance.sortedSeasons.first(where: { $0.seasonNumber == 1 }) { library.setWatched(s1, true) }
            let inception = try await library.addMovie(tmdbID: 27205)
            library.setWatched(inception, true)
            library.setRating(inception, 8)
            try await library.addShow(tmdbID: 1399) // Game of Thrones
            let upcoming = try await library.addMovie(tmdbID: 1_153_576) // Street Fighter, unreleased as of Sept 2026
            library.setBacklog(upcoming, true)
        }

        let tabs: [(AppTab, String)] = [(.discover, "discover"), (.nextToWatch, "next"), (.upcoming, "upcoming"),
                                        (.all, "library"), (.backlog, "backlog"), (.search, "search")]
        for (tab, name) in tabs {
            appState.selectedTab = tab
            try? await Task.sleep(for: .seconds(4))
            if let window = NSApp.windows.first(where: \.isVisible) { capture(window, to: output.appending(path: "\(name).png")) }
        }
        // Detail screens, hosted in their own windows since tab stacks have no programmatic path.
        let library = appState.library
        if let show = library.show(tmdbID: 95396) {
            await captureDetail(NavigationStack { TVShowDetailView(show: show) }, appState, output.appending(path: "show.png"))
        }
        if let movie = library.movie(tmdbID: 27205) {
            library.addNote("Rewatch in IMAX.", to: movie)
            await captureDetail(NavigationStack { MovieDetailView(movie: movie) }, appState, output.appending(path: "movie.png"))
        }
        NSApp.terminate(nil)
    }

    private static func captureDetail(_ view: some View, _ appState: AppState, _ url: URL) async {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 1100),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view.environment(appState).modelContainer(appState.container))
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .seconds(4))
        capture(window, to: url)
        window.close()
    }

    private static func capture(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
