#if DEBUG
import SwiftData
import SwiftUI
import ToWatchCore
#if os(macOS)
import AppKit
#endif

/// Debug-only helpers for checking the UI with real TMDB data in a throwaway in-memory library.
///
/// - `-UISeedSampleData YES` seeds sample titles (any platform; used with the iOS Simulator).
/// - `-UISnapshotDir <dir>` (macOS) also seeds, visits each tab, writes a PNG per screen, and quits.
///   The app captures its own windows, so no screen-recording permission is needed.
@MainActor
enum DebugTools {
    static var snapshotDir: String? { UserDefaults.standard.string(forKey: "UISnapshotDir") }
    static var usesSampleData: Bool { UserDefaults.standard.bool(forKey: "UISeedSampleData") || snapshotDir != nil }

    static func runIfRequested(_ appState: AppState) async {
        guard usesSampleData else { return }
        await seed(appState)
        #if os(macOS)
        if let snapshotDir { await snapshot(appState, to: URL(fileURLWithPath: snapshotDir, isDirectory: true)) }
        #endif
    }

    private static func seed(_ appState: AppState) async {
        await appState.perform { library in
            // Watch dates spread over this year and last, so stats have something to chart and compare.
            let calendar = Calendar.current
            let thisYear = calendar.component(.year, from: .now)
            func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
                calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 21))!
            }

            let severance = try await library.addShow(tmdbID: 95396)
            if let s1 = severance.sortedSeasons.first(where: { $0.seasonNumber == 1 }) {
                for (index, episode) in s1.sortedEpisodes.enumerated() {
                    library.setWatched(episode, true, on: day(thisYear, 1 + index % 8, 3 + index))
                }
            }
            let inception = try await library.addMovie(tmdbID: 27205)
            library.setWatched(inception, true, on: day(thisYear, 2, 14))
            library.setRating(inception, 8)
            library.addNote("Rewatch in IMAX.", to: inception)
            let thrones = try await library.addShow(tmdbID: 1399) // Game of Thrones
            if let s1 = thrones.sortedSeasons.first(where: { $0.seasonNumber == 1 }) {
                for (index, episode) in s1.sortedEpisodes.enumerated() {
                    library.setWatched(episode, true, on: day(thisYear - 1, 5 + index / 3, 1 + index))
                }
            }
            let dune = try await library.addMovie(tmdbID: 438_631) // Dune (2021)
            library.setWatched(dune, true, on: day(thisYear, 6, 20))
            let upcoming = try await library.addMovie(tmdbID: 1_153_576) // Street Fighter, unreleased as of Sept 2026
            library.setBacklog(upcoming, true)

            if let space = library.createSpace(name: "Mind Benders", symbolName: "brain", colorName: "purple") {
                library.toggle(.movie(inception), in: space)
                library.toggle(.show(severance), in: space)
            }
            if let tag = library.createTag(name: "Rewatch", colorName: "red") { library.toggle(tag, on: .movie(inception)) }
            var rules = SmartListRules()
            rules.media = .shows
            rules.statuses = [.notWatched, .watching]
            library.createSmartList(name: "Shows in Progress", symbolName: "play.tv", colorName: "orange", rules: rules)
        }
    }

    #if os(macOS)
    private static func snapshot(_ appState: AppState, to output: URL) async {
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var tabs: [(AppTab, String)] = [(.discover, "discover"), (.nextToWatch, "next"), (.upcoming, "upcoming"),
                                        (.all, "library"), (.backlog, "backlog"), (.search, "search"), (.organize, "organize"), (.stats, "stats")]
        let library = appState.library
        if let space = try? library.context.fetch(FetchDescriptor<Space>()).first { tabs.append((.space(space.uuid), "space")) }
        if let list = try? library.context.fetch(FetchDescriptor<SmartList>()).first { tabs.append((.smartList(list.uuid), "smartlist")) }
        for (tab, name) in tabs {
            appState.selectedTab = tab
            try? await Task.sleep(for: .seconds(4))
            if let window = NSApp.windows.first(where: \.isVisible) { capture(window, to: output.appending(path: "\(name).png")) }
        }
        // Detail screens, hosted in their own windows since tab stacks have no programmatic path.
        if let show = library.show(tmdbID: 95396) {
            await captureDetail(NavigationStack { TVShowDetailView(show: show) }, appState, output.appending(path: "show.png"))
        }
        if let movie = library.movie(tmdbID: 27205) {
            await captureDetail(NavigationStack { MovieDetailView(movie: movie) }, appState, output.appending(path: "movie.png"))
        }
        // Year in Review card, rendered the same way the share sheet renders it.
        let year = Calendar.current.component(.year, from: .now)
        let movies = (try? library.context.fetch(FetchDescriptor<Movie>())) ?? []
        let shows = (try? library.context.fetch(FetchDescriptor<TVShow>())) ?? []
        let stats = StatsService.stats(movies: movies, shows: shows, period: .year(year))
        let posters = await PosterLoader.load(stats.posterPaths.prefix(6))
        let renderer = ImageRenderer(content: YearInReviewCard(year: year, stats: stats, posters: posters))
        renderer.scale = 3
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: output.appending(path: "review.png"))
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
    #endif
}
#endif
