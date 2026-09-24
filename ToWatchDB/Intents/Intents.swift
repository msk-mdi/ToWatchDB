import AppIntents
import Foundation
import SwiftData
import ToWatchCore

// Siri and Shortcuts actions. Each is a thin wrapper over LibraryService; the sentences come from
// SpokenSummaries in ToWatchCore, where they're tested.

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case notInLibrary(String)
    case noToken

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case let .notInLibrary(name): "\(name) isn't in your library anymore."
        case .noToken: "ToWatchDB needs a TMDB access token. Add one in Settings."
        }
    }
}

// MARK: - Asking

struct GetNextEpisodesIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Next Episodes to Watch"
    static let description = IntentDescription("Lists the next unwatched episode of each show you're following.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let shows = (try? SharedLibrary.container.mainContext.fetch(FetchDescriptor<TVShow>())) ?? []
        let summary = SpokenSummaries.nextEpisodes(shows)
        return .result(value: summary, dialog: "\(summary)")
    }
}

struct GetUpcomingIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Upcoming Releases"
    static let description = IntentDescription("Lists movies and episodes from your library that come out today or later.")

    @Parameter(title: "How Many", default: 5, inclusiveRange: (1, 20))
    var limit: Int

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let context = SharedLibrary.container.mainContext
        let items = UpcomingService.upcoming(movies: (try? context.fetch(FetchDescriptor<Movie>())) ?? [],
                                             shows: (try? context.fetch(FetchDescriptor<TVShow>())) ?? [])
        let summary = SpokenSummaries.upcoming(items, limit: limit)
        return .result(value: summary, dialog: "\(summary)")
    }
}

struct GetWatchStatsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Watch Stats"
    static let description = IntentDescription("Tells you how many movies and episodes you watched, and for how long.")

    @Parameter(title: "Period", default: .thisYear)
    var period: StatsPeriodOption

    static var parameterSummary: some ParameterSummary {
        Summary("Get watch stats for \(\.$period)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let context = SharedLibrary.container.mainContext
        let statsPeriod = period.period
        let stats = StatsService.stats(movies: (try? context.fetch(FetchDescriptor<Movie>())) ?? [],
                                       shows: (try? context.fetch(FetchDescriptor<TVShow>())) ?? [],
                                       period: statsPeriod)
        let summary = SpokenSummaries.stats(stats, periodLabel: statsPeriod.label)
        return .result(value: summary, dialog: "\(summary)")
    }
}

struct WhereToWatchMovieIntent: AppIntent {
    static let title: LocalizedStringResource = "Where to Watch a Movie"
    static let description = IntentDescription("Finds where a movie streams, rents, or sells in your country. Powered by JustWatch.")

    @Parameter(title: "Movie")
    var movie: MovieEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Where can I watch \(\.$movie)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let client = SharedLibrary.makeClient() else { throw IntentError.noToken }
        let region = SharedLibrary.watchRegion
        let providers = try await client.watchProviders(movieID: movie.id)
        let summary = SpokenSummaries.whereToWatch(movie.title, offers: providers.results[region],
                                                   countryName: Locale.current.localizedString(forRegionCode: region) ?? region)
        return .result(value: summary, dialog: "\(summary)")
    }
}

struct WhereToWatchShowIntent: AppIntent {
    static let title: LocalizedStringResource = "Where to Watch a TV Show"
    static let description = IntentDescription("Finds where a show streams, rents, or sells in your country. Powered by JustWatch.")

    @Parameter(title: "TV Show")
    var show: ShowEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Where can I watch \(\.$show)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let client = SharedLibrary.makeClient() else { throw IntentError.noToken }
        let region = SharedLibrary.watchRegion
        let providers = try await client.watchProviders(showID: show.id)
        let summary = SpokenSummaries.whereToWatch(show.name, offers: providers.results[region],
                                                   countryName: Locale.current.localizedString(forRegionCode: region) ?? region)
        return .result(value: summary, dialog: "\(summary)")
    }
}

// MARK: - Changing

struct MarkNextEpisodeWatchedIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark Next Episode as Watched"
    static let description = IntentDescription("Marks the next unwatched episode of a show as watched today.")

    @Parameter(title: "TV Show")
    var show: ShowEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Mark the next episode of \(\.$show) as watched")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let library = SharedLibrary.service
        guard let model = library.show(tmdbID: show.id) else { throw IntentError.notInLibrary(show.name) }
        guard let episode = model.nextEpisodeToWatch() else {
            return .result(dialog: "You're all caught up on \(model.name).")
        }
        library.setWatched(episode, true)
        return .result(dialog: "\(SpokenSummaries.markedWatched(episode, next: model.nextEpisodeToWatch()))")
    }
}

struct MarkMovieWatchedIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark Movie as Watched"
    static let description = IntentDescription("Marks a movie in your library as watched.")

    @Parameter(title: "Movie")
    var movie: MovieEntity

    @Parameter(title: "Date Watched", description: "Leave empty for today.")
    var date: Date?

    static var parameterSummary: some ParameterSummary {
        Summary("Mark \(\.$movie) as watched") {
            \.$date
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let library = SharedLibrary.service
        guard let model = library.movie(tmdbID: movie.id) else { throw IntentError.notInLibrary(movie.title) }
        library.setWatched(model, true, on: date ?? .now)
        let when = date.map { " on \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
        return .result(dialog: "Marked \(model.title) as watched\(when).")
    }
}

struct RateMovieIntent: AppIntent {
    static let title: LocalizedStringResource = "Rate a Movie"
    static let description = IntentDescription("Gives a movie a rating from 1 to 5 stars.")

    @Parameter(title: "Movie")
    var movie: MovieEntity

    @Parameter(title: "Stars", inclusiveRange: (1, 5))
    var stars: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Rate \(\.$movie) \(\.$stars) stars")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let library = SharedLibrary.service
        guard let model = library.movie(tmdbID: movie.id) else { throw IntentError.notInLibrary(movie.title) }
        library.setRating(model, Double(stars * 2))
        return .result(dialog: "Rated \(model.title) \(stars) star\(stars == 1 ? "" : "s").")
    }
}

struct RateShowIntent: AppIntent {
    static let title: LocalizedStringResource = "Rate a TV Show"
    static let description = IntentDescription("Gives a show a rating from 1 to 5 stars.")

    @Parameter(title: "TV Show")
    var show: ShowEntity

    @Parameter(title: "Stars", inclusiveRange: (1, 5))
    var stars: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Rate \(\.$show) \(\.$stars) stars")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let library = SharedLibrary.service
        guard let model = library.show(tmdbID: show.id) else { throw IntentError.notInLibrary(show.name) }
        library.setRating(model, Double(stars * 2))
        return .result(dialog: "Rated \(model.name) \(stars) star\(stars == 1 ? "" : "s").")
    }
}

struct AddMovieToBacklogIntent: AppIntent {
    static let title: LocalizedStringResource = "Move Movie to Backlog"
    static let description = IntentDescription("Adds a movie from your library to the backlog.")

    @Parameter(title: "Movie")
    var movie: MovieEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Move \(\.$movie) to the backlog")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let library = SharedLibrary.service
        guard let model = library.movie(tmdbID: movie.id) else { throw IntentError.notInLibrary(movie.title) }
        library.setBacklog(model, true)
        return .result(dialog: "Moved \(model.title) to your backlog.")
    }
}

struct AddShowToBacklogIntent: AppIntent {
    static let title: LocalizedStringResource = "Move TV Show to Backlog"
    static let description = IntentDescription("Adds a show from your library to the backlog.")

    @Parameter(title: "TV Show")
    var show: ShowEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Move \(\.$show) to the backlog")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let library = SharedLibrary.service
        guard let model = library.show(tmdbID: show.id) else { throw IntentError.notInLibrary(show.name) }
        library.setBacklog(model, true)
        return .result(dialog: "Moved \(model.name) to your backlog.")
    }
}

struct AddNoteToMovieIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Note to Movie"
    static let description = IntentDescription("Saves a note on a movie in your library.")

    @Parameter(title: "Movie")
    var movie: MovieEntity

    @Parameter(title: "Note", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) to \(\.$movie)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let library = SharedLibrary.service
        guard let model = library.movie(tmdbID: movie.id) else { throw IntentError.notInLibrary(movie.title) }
        guard library.addNote(text, to: model) != nil else { return .result(dialog: "The note was empty, so nothing was saved.") }
        return .result(dialog: "Saved your note on \(model.title).")
    }
}

struct AddNoteToShowIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Note to TV Show"
    static let description = IntentDescription("Saves a note on a show in your library.")

    @Parameter(title: "TV Show")
    var show: ShowEntity

    @Parameter(title: "Note", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) to \(\.$show)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let library = SharedLibrary.service
        guard let model = library.show(tmdbID: show.id) else { throw IntentError.notInLibrary(show.name) }
        guard library.addNote(text, to: model) != nil else { return .result(dialog: "The note was empty, so nothing was saved.") }
        return .result(dialog: "Saved your note on \(model.name).")
    }
}

// MARK: - Opening the app

struct OpenListIntent: AppIntent {
    static let title: LocalizedStringResource = "Open List"
    static let description = IntentDescription("Opens Next to Watch, Upcoming, Backlog, Watched, Library, or Stats.")
    static let openAppWhenRun = true

    @Parameter(title: "List", default: .nextToWatch)
    var list: AppList

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.destination = list.destination
        return .result()
    }
}

struct OpenCollectionIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Space, Smart List, or Tag"
    static let description = IntentDescription("Opens one of your spaces, smart lists, or tags.")
    static let openAppWhenRun = true

    @Parameter(title: "Collection")
    var collection: CollectionEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.destination = .scope(collection.scope)
        return .result()
    }
}

struct OpenMovieIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Movie"
    static let description = IntentDescription("Opens a movie's page.")
    static let openAppWhenRun = true

    @Parameter(title: "Movie")
    var movie: MovieEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = SharedLibrary.service.movie(tmdbID: movie.id)
        IntentRouter.shared.title = model.map(TitleReference.init)
            ?? TitleReference(kind: .movie, tmdbID: movie.id, title: movie.title, posterPath: nil)
        return .result()
    }
}

struct OpenShowIntent: AppIntent {
    static let title: LocalizedStringResource = "Open TV Show"
    static let description = IntentDescription("Opens a show's page.")
    static let openAppWhenRun = true

    @Parameter(title: "TV Show")
    var show: ShowEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = SharedLibrary.service.show(tmdbID: show.id)
        IntentRouter.shared.title = model.map(TitleReference.init)
            ?? TitleReference(kind: .tv, tmdbID: show.id, title: show.name, posterPath: nil)
        return .result()
    }
}

struct SearchTMDBIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Movies and TV Shows"
    static let description = IntentDescription("Opens ToWatchDB to search TMDB.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.destination = .tab(.search)
        return .result()
    }
}

// MARK: - Siri phrases

struct ToWatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: GetNextEpisodesIntent(), phrases: [
            "What's next in \(.applicationName)",
            "What should I watch in \(.applicationName)",
            "My next episodes in \(.applicationName)",
        ], shortTitle: "Next Episodes", systemImageName: "play.circle")

        AppShortcut(intent: MarkNextEpisodeWatchedIntent(), phrases: [
            "Mark \(\.$show) watched in \(.applicationName)",
            "I watched \(\.$show) in \(.applicationName)",
            "Mark next episode watched in \(.applicationName)",
        ], shortTitle: "Mark Episode Watched", systemImageName: "checkmark.circle")

        AppShortcut(intent: GetUpcomingIntent(), phrases: [
            "What's coming up in \(.applicationName)",
            "Upcoming releases in \(.applicationName)",
        ], shortTitle: "Upcoming", systemImageName: "calendar")

        AppShortcut(intent: GetWatchStatsIntent(), phrases: [
            "My watch stats in \(.applicationName)",
            "How much did I watch in \(.applicationName)",
        ], shortTitle: "Watch Stats", systemImageName: "chart.bar.xaxis")

        AppShortcut(intent: WhereToWatchMovieIntent(), phrases: [
            "Where can I watch \(\.$movie) in \(.applicationName)",
            "Where to watch a movie in \(.applicationName)",
        ], shortTitle: "Where to Watch", systemImageName: "tv")

        AppShortcut(intent: WhereToWatchShowIntent(), phrases: [
            "Where can I stream \(\.$show) in \(.applicationName)",
            "Where to watch a show in \(.applicationName)",
        ], shortTitle: "Where to Watch Show", systemImageName: "tv.and.mediabox")

        AppShortcut(intent: OpenListIntent(), phrases: [
            "Open \(\.$list) in \(.applicationName)",
            "Show my \(\.$list) in \(.applicationName)",
        ], shortTitle: "Open List", systemImageName: "list.bullet")

        AppShortcut(intent: MarkMovieWatchedIntent(), phrases: [
            "I watched \(\.$movie) with \(.applicationName)",
            "Mark a movie watched in \(.applicationName)",
        ], shortTitle: "Mark Movie Watched", systemImageName: "film")

        AppShortcut(intent: SearchTMDBIntent(), phrases: [
            "Search \(.applicationName)",
            "Find a movie in \(.applicationName)",
        ], shortTitle: "Search", systemImageName: "magnifyingglass")
    }
}
