import Foundation
import SwiftData
import Testing
@testable import ToWatchCore

// MARK: - Helpers

private func fixture<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try TMDBClient.decoder.decode(T.self, from: Data(contentsOf: url))
}

private func date(_ string: String) -> Date { TMDBDate.parse(string)! }

private func episode(_ season: Int, _ number: Int, airs: String?) -> TMDBEpisode {
    TMDBEpisode(id: season * 1000 + number, episodeNumber: number, seasonNumber: season, name: "E\(number)",
                overview: nil, airDate: airs, runtime: 50, stillPath: nil, voteAverage: nil)
}

/// A context doesn't keep its container alive, so tests park containers here.
@MainActor private var liveContainers: [ModelContainer] = []

@MainActor
private func makeLibrary() throws -> LibraryService {
    let container = try ModelContainer(
        for: Schema(ToWatchSchema.models),
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    liveContainers.append(container)
    return LibraryService(context: container.mainContext, client: nil)
}

/// Severance as stored by TMDB, plus a synthetic second season whose last two episodes air in the future.
@MainActor
private func insertSeverance(into library: LibraryService) throws -> TVShow {
    let detail: TMDBTVDetail = try fixture("tv_severance")
    let season1: TMDBSeasonDetail = try fixture("season_1")
    let season2 = TMDBSeasonDetail(id: 2, seasonNumber: 2, name: "Season 2", overview: nil, posterPath: nil, airDate: "2025-01-16",
                                   episodes: [episode(2, 1, airs: "2025-01-16"), episode(2, 2, airs: "2030-01-01"), episode(2, 3, airs: "2030-01-08")])
    let specials = TMDBSeasonDetail(id: 0, seasonNumber: 0, name: "Specials", overview: nil, posterPath: nil, airDate: nil,
                                    episodes: [episode(0, 1, airs: "2021-12-15")])
    return library.insertShow(detail, seasons: [specials, season1, season2])
}

private let now = date("2026-09-23")

// MARK: - Decoding

@Test func decodesTVDetail() throws {
    let show: TMDBTVDetail = try fixture("tv_severance")
    #expect(show.name == "Severance")
    #expect(show.seasons?.map(\.seasonNumber).contains(1) == true)
    #expect(show.credits?.cast.isEmpty == false)
}

@Test func decodesMovieDetail() throws {
    let movie: TMDBMovieDetail = try fixture("movie_inception")
    #expect(movie.title == "Inception")
    #expect(movie.runtime == 148)
    #expect(movie.credits?.crew.contains { $0.name == "Christopher Nolan" } == true)
    #expect(movie.videos?.bestTrailerKey != nil)
}

@Test func decodesSeasonAndSearch() throws {
    let season: TMDBSeasonDetail = try fixture("season_1")
    #expect(season.episodes.count == 9)
    let search: TMDBPage<TMDBTVSummary> = try fixture("search_tv")
    #expect(search.results.first?.name == "Severance")
}

@Test func parsesTMDBDates() {
    #expect(TMDBDate.parse("") == nil)
    #expect(TMDBDate.parse(nil) == nil)
    #expect(TMDBDate.parse("2022-02-18") == Date(timeIntervalSince1970: 1_645_142_400))
}

// MARK: - Library

@MainActor @Test func addingTwiceDoesNotDuplicate() throws {
    let library = try makeLibrary()
    let movie: TMDBMovieDetail = try fixture("movie_inception")
    library.insertMovie(movie)
    library.insertMovie(movie)
    #expect(try library.context.fetchCount(FetchDescriptor<Movie>()) == 1)

    let first = try insertSeverance(into: library)
    let second = try insertSeverance(into: library)
    #expect(first.persistentModelID == second.persistentModelID)
    #expect(try library.context.fetchCount(FetchDescriptor<TVShow>()) == 1)
    #expect(try library.context.fetchCount(FetchDescriptor<Episode>()) == 13)
}

@MainActor @Test func movieMapping() throws {
    let library = try makeLibrary()
    let movie = library.insertMovie(try fixture("movie_inception"))
    #expect(movie.directors.map(\.name) == ["Christopher Nolan"])
    #expect(movie.cast.count == 5)
    #expect(movie.isReleased(asOf: now))
    #expect(movie.watchStatus == .notWatched)

    library.setBacklog(movie, true)
    library.setWatched(movie, true, on: now)
    #expect(movie.watchStatus == .watched)
    #expect(movie.watchedDate == now)
    #expect(!movie.isInBacklog, "watching something takes it off the backlog")
}

@MainActor @Test func showWatchStatusAndNextEpisode() throws {
    let library = try makeLibrary()
    let show = try insertSeverance(into: library)

    #expect(show.regularEpisodes.count == 12, "specials are excluded")
    #expect(show.watchStatus(asOf: now) == .notWatched)
    #expect(show.nextEpisodeToWatch(asOf: now)?.code == "S01E01")

    let season1 = try #require(show.sortedSeasons.first { $0.seasonNumber == 1 })
    library.setWatched(season1, true, on: now, now: now)
    #expect(season1.isFullyWatched)
    #expect(show.watchStatus(asOf: now) == .watching)
    #expect(show.nextEpisodeToWatch(asOf: now)?.code == "S02E01")

    let s2e1 = try #require(show.nextEpisodeToWatch(asOf: now))
    library.setWatched(s2e1, true, on: now)
    #expect(show.watchStatus(asOf: now) == .watched, "caught up on everything that has aired")
    #expect(show.nextEpisodeToWatch(asOf: now) == nil)
    #expect(show.nextEpisodeToAir(asOf: now)?.code == "S02E02")

    library.setAbandoned(show, true)
    #expect(show.watchStatus(asOf: now) == .abandoned)
}

@MainActor @Test func markWatchedUpToSkipsUnairedAndSpecials() throws {
    let library = try makeLibrary()
    let show = try insertSeverance(into: library)
    let s1e5 = try #require(show.regularEpisodes.first { $0.code == "S01E05" })

    library.markWatchedUpTo(s1e5, on: now, now: now)
    #expect(show.watchedEpisodeCount() == 5)
    #expect(show.nextEpisodeToWatch(asOf: now)?.code == "S01E06")
    #expect(show.sortedSeasons.first { $0.seasonNumber == 0 }?.sortedEpisodes.first?.isWatched == false)

    library.setWatched(show, true, on: now, now: now)
    #expect(show.watchedEpisodeCount() == 10, "unaired episodes aren't marked")
    library.setWatched(show, false)
    #expect(show.watchedEpisodeCount() == 0)
}

/// `progressSummary` walks the episodes unsorted; it must agree with the airing-order answers.
@MainActor @Test func progressSummaryMatchesAiringOrder() throws {
    let library = try makeLibrary()
    let show = try insertSeverance(into: library)
    let episodes = show.regularEpisodes
    // Watched out of order, with the latest date on an earlier episode.
    library.setWatched(episodes[0], true, on: date("2026-03-01"))
    library.setWatched(episodes[2], true, on: date("2026-05-01"))
    library.setWatched(episodes[9], true, on: date("2026-04-01"))

    let summary = show.progressSummary(asOf: now)
    let aired = episodes.filter { $0.hasAired(asOf: now) }
    #expect(summary.nextEpisode?.code == aired.first { !$0.isWatched }?.code)
    #expect(summary.nextEpisode?.code == "S01E02")
    #expect(summary.lastWatched == date("2026-05-01"))
    #expect(summary.airedCount == aired.count)
    #expect(summary.remainingCount == aired.count - 3)
    #expect(show.lastWatchedDate == date("2026-05-01"))
    #expect(show.nextEpisodeToWatch(asOf: now)?.code == "S01E02")
}

@MainActor @Test func refreshMergeKeepsWatchData() throws {
    let library = try makeLibrary()
    let show = try insertSeverance(into: library)
    let s1e1 = try #require(show.regularEpisodes.first)
    library.setWatched(s1e1, true, on: now)

    // Same payload again, as a refresh would deliver it.
    _ = try insertSeverance(into: library)
    #expect(try library.context.fetchCount(FetchDescriptor<Episode>()) == 13)
    #expect(show.regularEpisodes.first?.isWatched == true)
    #expect(show.regularEpisodes.first?.watchedDate == now)
}

@MainActor @Test func upcoming() throws {
    let library = try makeLibrary()
    let show = try insertSeverance(into: library)
    let released = library.insertMovie(try fixture("movie_inception"))
    let unreleased = Movie(tmdbID: 1, title: "Future Film")
    unreleased.releaseDate = date("2027-05-01")
    library.context.insert(unreleased)

    #expect(UpcomingService.upcomingMovies([released, unreleased], now: now).map(\.title) == ["Future Film"])
    #expect(UpcomingService.upcomingEpisodes([show], now: now).map(\.code) == ["S02E02", "S02E03"])

    let merged = UpcomingService.upcoming(movies: [unreleased], shows: [show], now: now)
    #expect(merged.map(\.id).first == "movie-1")
    // The store-side version gives the same list.
    #expect(UpcomingService.upcoming(in: library.context, now: now).map(\.id)
        == UpcomingService.upcoming(movies: [released, unreleased], shows: [show], now: now).map(\.id))
    #expect(UpcomingService.upcoming(in: library.context, now: now).map(\.id) == merged.map(\.id))

    library.setAbandoned(show, true)
    #expect(UpcomingService.upcomingEpisodes([show], now: now).isEmpty)
    #expect(UpcomingService.upcoming(in: library.context, now: now).map(\.id) == ["movie-1"])
    #expect(UpcomingService.daysUntil(date("2026-09-30"), now: now) == 7)
}

@MainActor @Test func ratingsAndNotes() throws {
    let library = try makeLibrary()
    let movie = library.insertMovie(try fixture("movie_inception"))
    library.setRating(movie, 14)
    #expect(movie.userRating == 10)
    library.setRating(movie, nil)
    #expect(movie.userRating == nil)

    #expect(library.addNote("   ", to: movie) == nil)
    let note = try #require(library.addNote("  Rewatch in IMAX ", to: movie))
    #expect(note.text == "Rewatch in IMAX")
    #expect(movie.notes?.count == 1)

    library.delete(movie)
    #expect(try library.context.fetchCount(FetchDescriptor<Note>()) == 0, "notes cascade with their movie")
}

// MARK: - Spaces, tags, smart lists

@MainActor @Test func spaceAndTagMembership() throws {
    let library = try makeLibrary()
    let movie = library.insertMovie(try fixture("movie_inception"))
    let show = try insertSeverance(into: library)

    let space = try #require(library.createSpace(name: "  Mind Benders ", symbolName: "brain", colorName: "purple"))
    #expect(space.name == "Mind Benders")
    #expect(library.createSpace(name: "   ") == nil)

    library.toggle(.movie(movie), in: space)
    library.toggle(.show(show), in: space)
    #expect(space.itemCount == 2)
    #expect(library.isIn(.movie(movie), space))

    library.toggle(.movie(movie), in: space)
    #expect(!library.isIn(.movie(movie), space))
    #expect(space.itemCount == 1)

    let tag = try #require(library.createTag(name: "Rewatch", colorName: "red"))
    #expect(library.createTag(name: "rewatch")?.persistentModelID == tag.persistentModelID, "tag names are case-insensitive")
    library.toggle(tag, on: .movie(movie))
    #expect(library.isTagged(.movie(movie), tag))
    #expect(library.tag(uuid: tag.uuid)?.name == "Rewatch")

    // Deleting a collection leaves its titles in the library.
    library.delete(tag)
    library.delete(space)
    #expect(movie.tags?.isEmpty == true)
    #expect(show.spaces?.isEmpty == true)
    #expect(try library.context.fetchCount(FetchDescriptor<Movie>()) == 1)
    #expect(try library.context.fetchCount(FetchDescriptor<TVShow>()) == 1)
}

@MainActor @Test func smartListRules() throws {
    let library = try makeLibrary()
    let movie = library.insertMovie(try fixture("movie_inception"))
    let show = try insertSeverance(into: library)
    let tag = try #require(library.createTag(name: "Rewatch"))
    let space = try #require(library.createSpace(name: "Weekend"))

    var rules = SmartListRules()
    #expect(rules.matches(movie) && rules.matches(show, now: now), "empty rules match everything")

    rules.media = .movies
    #expect(rules.matches(movie) && !rules.matches(show, now: now))

    rules = SmartListRules()
    rules.genres = ["Drama", "Documentary"]
    #expect(!rules.matches(movie), "Inception has no Drama/Documentary genre")
    #expect(rules.matches(show, now: now))

    rules = SmartListRules()
    rules.statuses = [.notWatched]
    #expect(rules.matches(movie) && rules.matches(show, now: now))
    library.setWatched(movie, true, on: now)
    #expect(!rules.matches(movie))

    rules = SmartListRules()
    rules.tagIDs = [tag.uuid]
    #expect(!rules.matches(movie))
    library.toggle(tag, on: .movie(movie))
    #expect(rules.matches(movie))

    rules = SmartListRules()
    rules.spaceIDs = [space.uuid]
    library.toggle(.show(show), in: space)
    #expect(rules.matches(show, now: now) && !rules.matches(movie))

    rules = SmartListRules()
    rules.minimumRating = 8
    #expect(!rules.matches(movie), "unrated never meets a minimum")
    library.setRating(movie, 8)
    #expect(rules.matches(movie))

    rules = SmartListRules()
    rules.releasedFrom = 2015
    #expect(!rules.matches(movie) && rules.matches(show, now: now), "Inception is 2010, Severance 2022")
    rules.releasedThrough = 2020
    #expect(!rules.matches(show, now: now))

    rules = SmartListRules()
    rules.backlogOnly = true
    rules.favoritesOnly = true
    library.setBacklog(show, true)
    #expect(!rules.matches(show, now: now))
    library.setFavorite(show, true)
    #expect(rules.matches(show, now: now))
}

@MainActor @Test func smartListPersistsRules() throws {
    let library = try makeLibrary()
    var rules = SmartListRules()
    rules.media = .shows
    rules.statuses = [.watching]
    let list = try #require(library.createSmartList(name: "In Progress", rules: rules))
    #expect(library.smartList(uuid: list.uuid)?.rules == rules)

    rules.favoritesOnly = true
    library.update(list, name: "Favorite Shows", symbolName: "heart", colorName: "pink", rules: rules)
    #expect(list.rules.favoritesOnly && list.name == "Favorite Shows")
}

// MARK: - Stats

private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    return calendar
}

@MainActor @Test func statsByPeriod() throws {
    let library = try makeLibrary()
    let movie = library.insertMovie(try fixture("movie_inception"))
    let show = try insertSeverance(into: library)
    let season1 = try #require(show.sortedSeasons.first { $0.seasonNumber == 1 })

    library.setWatched(movie, true, on: date("2024-12-31"))
    library.setWatched(season1, true, on: date("2025-03-10"), now: now)
    let undated = Movie(tmdbID: 2, title: "Undated")
    undated.runtime = 100
    library.context.insert(undated)
    library.setWatched(undated, true, on: nil)

    let calendar = utcCalendar
    let y2025 = StatsService.stats(movies: [movie, undated], shows: [show], period: .year(2025), now: now, calendar: calendar)
    let s1Minutes = season1.sortedEpisodes.compactMap(\.runtime).reduce(0, +)
    #expect(y2025.moviesWatched == 0)
    #expect(y2025.episodesWatched == 9)
    #expect(y2025.showsWatched == 1)
    #expect(y2025.episodeMinutes == s1Minutes && s1Minutes > 0)
    #expect(y2025.mostWatchedShow?.name == "Severance")
    #expect(y2025.activity.count == 12, "one bucket per month")
    #expect(y2025.granularity == .month)
    #expect(y2025.activity[2].episodes == 9, "all in March")
    #expect(y2025.topGenres.map(\.name).contains("Drama"))
    #expect(y2025.undatedWatches == 1)

    let y2024 = StatsService.stats(movies: [movie, undated], shows: [show], period: .year(2024), now: now, calendar: calendar)
    #expect(y2024.moviesWatched == 1 && y2024.movieMinutes == 148)
    #expect(y2024.longestMovie?.name == "Inception")
    #expect(y2024.topActors.contains { $0.name == "Leonardo DiCaprio" })
    #expect(y2024.activity[11].movies == 1, "December")

    let all = StatsService.stats(movies: [movie, undated], shows: [show], period: .allTime, now: now, calendar: calendar)
    #expect(all.moviesWatched == 2, "undated watches count toward all time")
    #expect(all.totalMinutes == 148 + 100 + s1Minutes)
    #expect(all.posterPaths.first == show.posterPath, "most recent first")

    #expect(StatsService.watchYears(movies: [movie, undated], shows: [show], calendar: calendar) == [2025, 2024])
}

@Test func statsPeriodsAndRanking() {
    let calendar = utcCalendar
    let week = StatsPeriod.lastDays(7).interval(now: date("2026-09-23"), calendar: calendar)
    #expect(week?.start == date("2026-09-17") && week?.end == date("2026-09-24"))
    #expect(StatsService.granularity(for: week!) == .day)
    #expect(StatsService.granularity(for: StatsPeriod.year(2025).interval(calendar: calendar)!) == .month)
    #expect(StatsPeriod.allTime.interval() == nil)

    let ranked = StatsService.rank([("a", "Drama", nil), ("b", "Action", nil), ("a", "Drama", nil), ("c", "Comedy", nil)], limit: 2)
    #expect(ranked.map(\.name) == ["Drama", "Action"], "count first, then alphabetical")
    #expect(ranked.first?.count == 2)
}

// MARK: - Where to watch

@Test func decodesWatchProviders() throws {
    let providers: TMDBWatchProviders = try fixture("providers_inception")
    #expect(providers.id == 27205)
    #expect(Set(providers.results.keys) == ["US", "FR", "DE"], "country codes survive snake_case key conversion")

    let france = try #require(providers.results["FR"])
    #expect(france.link?.contains("locale=FR") == true)
    let kinds = france.sections.map(\.kind)
    #expect(kinds.contains(.rent))
    #expect(kinds == TMDBCountryProviders.Kind.allCases.filter(kinds.contains), "sections keep a fixed order")
    for section in france.sections {
        let priorities = section.providers.map { $0.displayPriority ?? .max }
        #expect(priorities == priorities.sorted())
    }

    let english = providers.countries(locale: Locale(identifier: "en_US"))
    #expect(english == ["FR", "DE", "US"], "France, Germany, United States")
}

// MARK: - Backup

@MainActor @Test func backupRoundTripsIntoEmptyLibrary() throws {
    let source = try makeLibrary()
    let movie = source.insertMovie(try fixture("movie_inception"))
    let show = try insertSeverance(into: source)
    source.setWatched(movie, true, on: date("2024-12-31"))
    source.setRating(movie, 8)
    source.addNote("Rewatch in IMAX", to: movie)
    let s1e1 = try #require(show.regularEpisodes.first)
    source.setWatched(s1e1, true, on: date("2025-01-02"))
    source.addNote("Great pilot", to: s1e1)
    source.setAbandoned(show, true)
    let space = try #require(source.createSpace(name: "Mind Benders", symbolName: "brain", colorName: "purple"))
    source.toggle(.movie(movie), in: space)
    let tag = try #require(source.createTag(name: "Rewatch", colorName: "red"))
    source.toggle(tag, on: .show(show))
    var rules = SmartListRules()
    rules.tagIDs = [tag.uuid]
    source.createSmartList(name: "Rewatches", rules: rules)

    let data = try source.exportBackupData()
    let target = try makeLibrary()
    let summary = try target.importBackup(data: data)
    #expect(summary.moviesAdded == 1 && summary.showsAdded == 1 && summary.collectionsAdded == 3)

    let restoredMovie = try #require(target.movie(tmdbID: movie.tmdbID))
    #expect(restoredMovie.title == "Inception" && restoredMovie.runtime == 148)
    #expect(restoredMovie.isWatched && restoredMovie.watchedDate == date("2024-12-31") && restoredMovie.userRating == 8)
    #expect(restoredMovie.notes?.map(\.text) == ["Rewatch in IMAX"])
    #expect(restoredMovie.directors.map(\.name) == ["Christopher Nolan"], "metadata restored offline")
    #expect(restoredMovie.spaces?.map(\.name) == ["Mind Benders"])

    let restoredShow = try #require(target.show(tmdbID: show.tmdbID))
    #expect(restoredShow.isAbandoned)
    #expect(restoredShow.regularEpisodes.count == 12)
    #expect(restoredShow.regularEpisodes.first?.isWatched == true)
    #expect(restoredShow.regularEpisodes.first?.notes?.first?.text == "Great pilot")
    #expect(restoredShow.tags?.map(\.name) == ["Rewatch"])

    let restoredList = try #require(try target.context.fetch(FetchDescriptor<SmartList>()).first)
    #expect(restoredList.rules.matches(restoredShow, now: now), "rules still point at the restored tag")
}

@MainActor @Test func backupImportMergesWithoutDuplicates() throws {
    let library = try makeLibrary()
    let movie = library.insertMovie(try fixture("movie_inception"))
    let show = try insertSeverance(into: library)
    library.addNote("Rewatch in IMAX", to: movie)
    library.setWatched(try #require(show.regularEpisodes.first), true, on: date("2025-01-02"))
    let backup = try library.exportBackupData()

    // Local changes after the backup: they must survive the import.
    library.setRating(movie, 6)
    library.setWatched(try #require(show.regularEpisodes.dropFirst().first), true, on: date("2025-01-03"))

    // Importing twice changes nothing the second time and never duplicates.
    for _ in 0..<2 {
        let summary = try library.importBackup(data: backup)
        #expect(summary.moviesAdded == 0 && summary.moviesMerged == 1 && summary.showsMerged == 1)
    }
    #expect(try library.context.fetchCount(FetchDescriptor<Movie>()) == 1)
    #expect(try library.context.fetchCount(FetchDescriptor<Episode>()) == 13)
    #expect(try library.context.fetchCount(FetchDescriptor<Note>()) == 1)
    #expect(movie.userRating == 6, "local rating wins")
    #expect(show.watchedEpisodeCount() == 2, "watched on either side stays watched")
}

@Test func backupRejectsNewerFormatsAndJunk() {
    #expect(throws: BackupError.self) { try BackupCoding.decode(Data(#"{"version": 99}"#.utf8)) }
    #expect(throws: BackupError.self) { try BackupCoding.decode(Data("not json".utf8)) }
}

@MainActor @Test func csvExport() throws {
    let library = try makeLibrary()
    let movie = library.insertMovie(try fixture("movie_inception"))
    movie.title = #"Inception, "Director's Cut""#
    library.setWatched(movie, true, on: date("2024-12-31"))
    _ = try insertSeverance(into: library)

    let csv = try library.exportCSV(now: now)
    let lines = csv.split(separator: "\r\n")
    #expect(lines.count == 3)
    #expect(lines[0].hasPrefix("Type,TMDB ID,Title"))
    #expect(lines[1].contains(#""Inception, ""Director's Cut""""#), "quotes and commas are escaped")
    #expect(lines[1].contains("2024-12-31"))
    #expect(lines[2].hasPrefix("TV Show,95396,Severance,2022,Not Watched"))
}

// MARK: - Spoken summaries

@MainActor @Test func spokenSummaries() throws {
    let library = try makeLibrary()
    let show = try insertSeverance(into: library)
    #expect(SpokenSummaries.nextEpisodes([show], now: now) == "You have 1 show to continue: Severance S01E01.")

    let s1e1 = try #require(show.regularEpisodes.first)
    library.setWatched(s1e1, true, on: now)
    let next = show.nextEpisodeToWatch(asOf: now)
    #expect(SpokenSummaries.markedWatched(s1e1, next: next).hasPrefix("Marked Severance S01E01 as watched. Next up: S01E02"))

    library.setWatched(show, true, on: now, now: now)
    #expect(SpokenSummaries.nextEpisodes([show], now: now) == "You're all caught up. No episodes left to watch.")

    let upcoming = UpcomingService.upcoming(movies: [], shows: [show], now: now)
    #expect(SpokenSummaries.upcoming(upcoming, limit: 1, now: now).hasPrefix("Coming up: Severance S02E02 on "))
    #expect(SpokenSummaries.upcoming(upcoming, limit: 1, now: now).hasSuffix(", and 1 more."))
    #expect(SpokenSummaries.upcoming([], now: now) == "Nothing from your library is coming up.")

    var stats = WatchStats()
    #expect(SpokenSummaries.stats(stats, periodLabel: "2025") == "You haven't watched anything in 2025.")
    stats.moviesWatched = 1
    stats.episodesWatched = 9
    stats.movieMinutes = 148
    stats.episodeMinutes = 60
    #expect(SpokenSummaries.stats(stats, periodLabel: "Last 30 Days")
        == "In the last 30 days you watched 1 movie and 9 episodes, 3 hours, 28 minutes in total.")
}

@Test func spokenWhereToWatch() throws {
    let providers: TMDBWatchProviders = try fixture("providers_inception")
    let sentence = SpokenSummaries.whereToWatch("Inception", offers: providers.results["FR"], countryName: "France")
    #expect(sentence.hasPrefix("In France, you can stream on "))
    #expect(sentence.contains("rent on Apple TV Store"))
    #expect(SpokenSummaries.whereToWatch("Inception", offers: nil, countryName: "Chad")
        == "Inception isn't available to stream, rent, or buy in Chad.")
}

// MARK: - Bug fixes

@Test func trailersFallBackToEnglish() {
    #expect(TMDBClient(token: "t", language: "fr-FR").videoLanguages == "fr,en,null")
    #expect(TMDBClient(token: "t", language: "en-US").videoLanguages == "en,null")
}

@MainActor
@Test func deletingSpaceOrTagCleansSmartListRules() throws {
    let library = try makeLibrary()
    let space = try #require(library.createSpace(name: "Family"))
    let tag = try #require(library.createTag(name: "Rewatch"))
    var rules = SmartListRules()
    rules.spaceIDs = [space.uuid]
    rules.tagIDs = [tag.uuid]
    let list = try #require(library.createSmartList(name: "Mixed", rules: rules))

    library.delete(space)
    library.delete(tag)
    #expect(list.rules.spaceIDs.isEmpty)
    #expect(list.rules.tagIDs.isEmpty)
}

@MainActor
@Test func importPointsSmartListRulesAtTagsMatchedByName() throws {
    let source = try makeLibrary()
    let sourceTag = try #require(source.createTag(name: "Rewatch"))
    var rules = SmartListRules()
    rules.tagIDs = [sourceTag.uuid]
    source.createSmartList(name: "Rewatches", rules: rules)
    let backup = try source.makeBackup()

    let target = try makeLibrary()
    let localTag = try #require(target.createTag(name: "rewatch"))
    target.importBackup(backup)
    let imported = try #require(try target.context.fetch(FetchDescriptor<SmartList>()).first)
    #expect(imported.rules.tagIDs == [localTag.uuid])
}

@MainActor
@Test func csvDatesAreLocalDays() throws {
    let library = try makeLibrary()
    let movie = Movie(tmdbID: 1, title: "Late Show")
    library.context.insert(movie)
    // 23:30 in New York is already the next day in UTC.
    let lateEvening = try Date("2026-03-10T23:30:00-04:00", strategy: .iso8601)
    library.setWatched(movie, true, on: lateEvening)
    let csv = try library.exportCSV(timeZone: TimeZone(identifier: "America/New_York")!)
    #expect(csv.contains("2026-03-10"))
    #expect(!csv.contains("2026-03-11"))
}

// MARK: - List import

@Test func parsesExportedTitleLists() {
    let text = """
    MOVIES
    ======
    Adaptation. (2002) - comedy, crime, drama
    Crazy, Stupid, Love. (2011) - comedy, drama, romance
    Æon Flux (2005) - action, sciencefiction, thriller
    Once Upon a Time... in Hollywood (2019) - comedy, drama, thriller

    TV SHOWS
    ========
    The Sopranos (1999) - crime, drama - 6 season(s), 86 episodes
    - Spare Me, Great Lord! (2021)
    3. Untitled Show
    """
    let entries = ListImport.parse(text)
    #expect(entries.map(\.label) == ["Adaptation. (2002)", "Crazy, Stupid, Love. (2011)", "Æon Flux (2005)",
                                     "Once Upon a Time... in Hollywood (2019)", "The Sopranos (1999)",
                                     "Spare Me, Great Lord! (2021)", "Untitled Show"])
    #expect(entries.map(\.kind) == [.movie, .movie, .movie, .movie, .show, .show, .show])
    #expect(entries.first?.line == 3)
}

@Test func matchesListTitlesOnTMDB() {
    typealias C = ListImport.Candidate
    // A regional re-release year still finds the film by its exact title.
    #expect(ListImport.bestMatch([C(id: 1, titles: ["Princess Mononoke Returns"], year: 2022),
                                  C(id: 2, titles: ["Princess Mononoke", "もののけ姫"], year: 1997)],
                                 title: "Princess Mononoke", year: 2022) == 2)
    // Same title, different films: the year decides.
    #expect(ListImport.bestMatch([C(id: 1, titles: ["Brothers"], year: 2024), C(id: 2, titles: ["Brothers"], year: 2009)],
                                 title: "Brothers", year: 2009) == 2)
    // Accents, punctuation, and "&" don't matter.
    #expect(ListImport.bestMatch([C(id: 7, titles: ["Æon Flux"], year: 2005)], title: "Aeon Flux", year: 2005) == 7)
    #expect(ListImport.bestMatch([C(id: 8, titles: ["Pride and Prejudice"], year: 2005)], title: "Pride & Prejudice", year: 2005) == 8)
    // A romanized title: TMDB's top result with the right year is taken, a lower one isn't.
    #expect(ListImport.bestMatch([C(id: 9, titles: ["Heavenly Delusion", "天国大魔境"], year: 2023)],
                                 title: "Tengoku Daimakyo", year: 2023) == 9)
    #expect(ListImport.bestMatch([C(id: 1, titles: ["Something Else"], year: 2010), C(id: 9, titles: ["Other"], year: 2023)],
                                 title: "Tengoku Daimakyo", year: 2023) == nil)
    #expect(ListImport.bestMatch([], title: "Anything", year: nil) == nil)
    // A regional year (2001) shouldn't pull in a lesser entry whose title only matches without punctuation.
    #expect(ListImport.bestMatch([C(id: 1, titles: ["In the Mood for Love", "花樣年華"], year: 2000),
                                  C(id: 2, titles: ["@ in the mood for love"], year: 2001)],
                                 title: "In the Mood for Love", year: 2001) == 1)
}
