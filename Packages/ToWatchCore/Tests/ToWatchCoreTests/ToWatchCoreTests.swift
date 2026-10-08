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

// Noon UTC, so it falls on Sep 23 in every time zone within ±12 hours: "today" is the local day.
private let now = date("2026-09-23").addingTimeInterval(12 * 3600)

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

@Test func decodesIMDbRatings() throws {
    let rated = Data(#"{"Title":"Inception","imdbRating":"8.8","imdbVotes":"2,876,809","Response":"True"}"#.utf8)
    #expect(try IMDbClient.decode(rated) == IMDbRating(value: 8.8, votes: 2_876_809))
    // A title without a rating, and an ID OMDb doesn't know, are answered with no rating.
    let unrated = Data(#"{"Title":"Upcoming","imdbRating":"N/A","imdbVotes":"N/A","Response":"True"}"#.utf8)
    #expect(try IMDbClient.decode(unrated) == nil)
    let unknown = Data(#"{"Response":"False","Error":"Incorrect IMDb ID."}"#.utf8)
    #expect(try IMDbClient.decode(unknown) == nil)
}

@Test func imdbErrorsDontReadAsMissingRatings() throws {
    // A wrong key or a used-up daily limit stops the lookups; other errors only leave that title out.
    let limited = Data(#"{"Response":"False","Error":"Request limit reached!"}"#.utf8)
    #expect(throws: IMDbClient.Rejected.self) { try IMDbClient.decode(limited) }
    let invalidKey = Data(#"{"Response":"False","Error":"Invalid API key!"}"#.utf8)
    #expect(throws: IMDbClient.Rejected.self) { try IMDbClient.decode(invalidKey) }
    let failed = Data(#"{"Response":"False","Error":"Error getting data."}"#.utf8)
    #expect(throws: URLError.self) { try IMDbClient.decode(failed) }
}

@Test func todayIsTheUsersLocalDay() throws {
    let pacific = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
    // 6 pm on Sep 22 in California is already Sep 23 in UTC; 8 am on Sep 23 in Tokyo is still Sep 22 in UTC.
    #expect(TMDBDate.today(date("2026-09-23").addingTimeInterval(3600), timeZone: pacific) == date("2026-09-22"))
    #expect(TMDBDate.today(date("2026-09-22").addingTimeInterval(23 * 3600), timeZone: tokyo) == date("2026-09-23"))
    #expect(TMDBDate.today(now, timeZone: .gmt) == date("2026-09-23"))
    #expect(TMDBDate.day(of: date("2026-09-23").addingTimeInterval(3600)) == date("2026-09-23"))
}

@Test func tmdbLanguageFromLocale() {
    #expect(TMDBClient.language(for: Locale(identifier: "en_US@calendar=buddhist")) == "en-US")
    #expect(TMDBClient.language(for: Locale(identifier: "es_419")) == "es")
    #expect(TMDBClient.language(for: Locale(identifier: "fr")) == "fr")
}

@Test func imdbLookupsOnlyTakePlainIDs() {
    #expect(IMDbClient.isValidID("tt1375666"))
    #expect(!IMDbClient.isValidID("tt"))
    #expect(!IMDbClient.isValidID("tt1\") { x }"))
    #expect(!IMDbClient.isValidID("nm0634240"))
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

@MainActor @Test func refreshRemovesEpisodesTMDBDropped() throws {
    let library = try makeLibrary()
    let show = try insertSeverance(into: library)
    let detail: TMDBTVDetail = try fixture("tv_severance")
    let season1: TMDBSeasonDetail = try fixture("season_1")
    let s2e1 = try #require(show.regularEpisodes.first { $0.code == "S02E01" })
    library.setWatched(s2e1, true, on: now)

    // TMDB now lists only season 1 (no specials, no season 2), and season 1 without its last episode.
    let trimmed = TMDBSeasonDetail(id: season1.id, seasonNumber: 1, name: season1.name, overview: nil, posterPath: nil,
                                   airDate: season1.airDate, episodes: Array(season1.episodes.dropLast()))
    library.insertShow(detail, seasons: [trimmed])
    #expect(show.regularEpisodes.map(\.code) == (1...8).map { String(format: "S01E%02d", $0) } + ["S02E01"],
            "the watched episode stays; unwatched ones TMDB dropped go")
    #expect(show.sortedSeasons.map(\.seasonNumber) == [1, 2])
    #expect(try library.context.fetchCount(FetchDescriptor<Episode>()) == 9)
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

// MARK: - Sync

/// One device's side of a sync through a shared file, as the app does it with Dropbox.
@MainActor
private final class SyncDevice {
    let library: LibraryService
    var base: LibraryBackup?

    init() throws { library = try makeLibrary() }

    /// Returns whether the merge changed this device's library.
    @discardableResult
    func sync(_ file: inout LibraryBackup?) throws -> Bool {
        var changed = false
        if let remote = file {
            let merged = LibrarySync.merge(base: base, local: try library.makeBackup(), remote: remote)
            changed = try library.applySyncedBackup(merged)
        }
        let snapshot = LibrarySync.normalized(try library.makeBackup())
        file = snapshot
        base = snapshot
        return changed
    }
}

@MainActor @Test func syncCombinesDevicesThenCarriesRemovals() throws {
    let mac = try SyncDevice(), phone = try SyncDevice()
    var file: LibraryBackup?
    let movie = mac.library.insertMovie(try fixture("movie_inception"))
    mac.library.setWatched(movie, true, on: date("2024-12-31"))
    mac.library.addNote("Rewatch in IMAX", to: movie)
    let show = try insertSeverance(into: phone.library)
    phone.library.setWatched(try #require(show.regularEpisodes.first), true, on: date("2025-01-02"))

    try mac.sync(&file)
    try phone.sync(&file)
    try mac.sync(&file)
    let phoneMovie = try #require(phone.library.movie(tmdbID: movie.tmdbID))
    let macShow = try #require(mac.library.show(tmdbID: show.tmdbID))
    #expect(phoneMovie.isWatched && phoneMovie.watchedDate == date("2024-12-31"))
    #expect(phoneMovie.notes?.map(\.text) == ["Rewatch in IMAX"])
    #expect(macShow.watchedEpisodeCount() == 1 && macShow.regularEpisodes.count == 12)

    // Un-watching, deleting a note, and removing a title all reach the other device.
    phone.library.setWatched(phoneMovie, false)
    phone.library.delete(try #require(phoneMovie.notes?.first))
    try phone.sync(&file)
    mac.library.delete(macShow)
    try mac.sync(&file)
    try phone.sync(&file)
    #expect(!movie.isWatched && movie.notes?.isEmpty == true)
    #expect(phone.library.show(tmdbID: show.tmdbID) == nil)
    #expect(try phone.library.context.fetchCount(FetchDescriptor<Episode>()) == 0)
}

/// A refresh removes episodes TMDB dropped; the file still lists them, but without user data they stay gone.
@MainActor @Test func syncDoesntBringBackEpisodesARefreshRemoved() throws {
    let mac = try SyncDevice(), phone = try SyncDevice()
    var file: LibraryBackup?
    let show = try insertSeverance(into: mac.library)
    try mac.sync(&file)
    try phone.sync(&file)
    let phoneShow = try #require(phone.library.show(tmdbID: show.tmdbID))
    phone.library.setWatched(try #require(phoneShow.regularEpisodes.first { $0.code == "S02E02" }), true, on: now)
    try phone.sync(&file)

    // TMDB drops the specials and S02E03, and only the Mac refreshes.
    let season2 = TMDBSeasonDetail(id: 2, seasonNumber: 2, name: "Season 2", overview: nil, posterPath: nil, airDate: "2025-01-16",
                                   episodes: [episode(2, 1, airs: "2025-01-16"), episode(2, 2, airs: "2030-01-01")])
    mac.library.insertShow(try fixture("tv_severance"), seasons: [try fixture("season_1"), season2])
    try mac.sync(&file)
    #expect(!show.regularEpisodes.contains { $0.code == "S02E03" })
    #expect(show.sortedSeasons.map(\.seasonNumber) == [1, 2])
    #expect(show.regularEpisodes.first { $0.code == "S02E02" }?.isWatched == true)
}

@MainActor @Test func notesAddedInOneSecondStayApart() throws {
    let library = try makeLibrary()
    let movie = library.insertMovie(try fixture("movie_inception"))
    library.addNote("One", to: movie)
    library.addNote("Two", to: movie)
    let keys = Set((movie.notes ?? []).map { LibrarySync.noteKey($0.createdAt) })
    #expect(keys.count == 2)
}

@Test func smartListRulesMissingFieldsTakeDefaults() throws {
    let rules = try JSONDecoder().decode(SmartListRules.self, from: Data(#"{"media":"movies","genres":["Drama"]}"#.utf8))
    #expect(rules.media == .movies && rules.genres == ["Drama"])
    #expect(!rules.backlogOnly && rules.statuses.isEmpty && rules.releasedFrom == nil)
}

/// After applying a downloaded file, the driver makes that file the base: if its upload then conflicts, the retry
/// must see what the file brought in as the other device's edits, not this one's.
@MainActor @Test func syncRetryMergesAgainstTheFileItApplied() throws {
    let mac = try SyncDevice(), phone = try SyncDevice()
    var file: LibraryBackup?
    let movie = mac.library.insertMovie(try fixture("movie_inception"))
    try mac.sync(&file)
    try phone.sync(&file)
    let phoneMovie = try #require(phone.library.movie(tmdbID: movie.tmdbID))

    // The phone rates it 8 and uploads. The Mac downloads and applies that file, but its upload conflicts…
    phone.library.setRating(phoneMovie, 8)
    try phone.sync(&file)
    let applied = try #require(file)
    _ = try mac.library.applySyncedBackup(LibrarySync.merge(base: mac.base, local: try mac.library.makeBackup(), remote: applied))
    mac.base = applied
    // …because the phone changed the rating again meanwhile. The retry keeps the newer rating.
    phone.library.setRating(phoneMovie, 6)
    try phone.sync(&file)
    try mac.sync(&file)
    #expect(movie.userRating == 6)
}

@MainActor @Test func lostLibrarySyncsAsFirstSync() throws {
    let mac = try SyncDevice()
    var file: LibraryBackup?
    for id in 1...5 { mac.library.context.insert(Movie(tmdbID: id, title: "Film \(id)")) }
    mac.library.save()
    try mac.sync(&file)
    let base = try #require(mac.base)

    // The store was recreated empty while the base file survived: merging against that base would empty the file.
    let empty = try makeLibrary().makeBackup()
    #expect(LibrarySync.usableBase(base, local: empty) == nil)
    #expect(LibrarySync.merge(base: LibrarySync.usableBase(base, local: empty), local: empty, remote: try #require(file)).movies.count == 5)
    // A library emptied by hand from a few titles keeps its base, so the deletions carry.
    var small = base
    small.movies.removeLast(3)
    #expect(LibrarySync.usableBase(small, local: empty) != nil)
}

@Test func syncIgnoresTMDBAndIMDbDetails() throws {
    var a = LibraryBackup(), b = LibraryBackup()
    let movie = LibraryBackup.MovieRecord(
        tmdbID: 1, title: "Film", genres: [], cast: [], directors: [], addedDate: date("2026-01-01"), isWatched: false,
        isInBacklog: true, isFavorite: false, notes: [], spaceIDs: [], tagIDs: [])
    a.movies = [movie]
    b.movies = [movie]
    b.movies[0].imdbRating = 7.9
    b.movies[0].overview = "Refreshed on another device."
    #expect(LibrarySync.sameContent(a, b))
    b.movies[0].userRating = 8
    #expect(!LibrarySync.sameContent(a, b))
}

@MainActor @Test func importAndSyncReuseNewerIMDbRatings() throws {
    let mac = try SyncDevice(), phone = try SyncDevice()
    var file: LibraryBackup?
    let movie = mac.library.insertMovie(try fixture("movie_inception"))
    movie.applyIMDbRating(IMDbRating(value: 8.7, votes: 100), on: date("2026-01-01"))
    try mac.sync(&file)
    try phone.sync(&file)

    // A title new to the phone arrives with the rating and its date, marked as imported.
    let phoneMovie = try #require(phone.library.movie(tmdbID: movie.tmdbID))
    #expect(phoneMovie.imdbRating == 8.7 && phoneMovie.imdbVoteCount == 100)
    #expect(phoneMovie.imdbRatingDate == date("2026-01-01") && phoneMovie.imdbRatingIsImported)

    // A rating the mac fetched later replaces the phone's older one on the next sync; an older one doesn't.
    movie.applyIMDbRating(IMDbRating(value: 8.8, votes: 200), on: date("2026-01-09"))
    try mac.sync(&file)
    try phone.sync(&file)
    #expect(phoneMovie.imdbRating == 8.8 && phoneMovie.imdbRatingDate == date("2026-01-09"))
    #expect(!movie.imdbRatingIsImported)
    phoneMovie.applyIMDbRating(IMDbRating(value: 9.0, votes: 300), on: date("2026-01-12"))
    var stale = try #require(file)
    stale.movies[0].imdbRating = 1
    stale.movies[0].imdbRatingDate = date("2026-01-02")
    phone.library.importBackup(stale)
    #expect(phoneMovie.imdbRating == 9.0 && !phoneMovie.imdbRatingIsImported)

    // Importing a backup takes a newer rating too.
    let restored = try makeLibrary()
    restored.insertMovie(try fixture("movie_inception"))
    restored.importBackup(try phone.library.makeBackup())
    let restoredMovie = try #require(restored.movie(tmdbID: movie.tmdbID))
    #expect(restoredMovie.imdbRating == 9.0 && restoredMovie.imdbRatingIsImported)
}

@MainActor @Test func deletedModelsAreNotLive() throws {
    let library = try makeLibrary()
    let movie = library.insertMovie(try fixture("movie_inception"))
    let space = try #require(library.createSpace(name: "Mind Benders", symbolName: "brain", colorName: "purple"))
    #expect(movie.isLive && space.isLive)

    library.context.delete(movie)
    #expect(!movie.isLive, "an unsaved deletion counts")
    library.delete(space)
    #expect(!space.isLive)
    // An editor still holding the deleted space saves or deletes it again: nothing happens.
    library.update(space, name: "Renamed", symbolName: "star", colorName: "red")
    library.delete(space)
    #expect(try library.context.fetchCount(FetchDescriptor<Space>()) == 0)
}

@MainActor @Test func syncKeepsEditsMadeOnBothDevices() throws {
    let mac = try SyncDevice(), phone = try SyncDevice()
    var file: LibraryBackup?
    let movie = mac.library.insertMovie(try fixture("movie_inception"))
    try mac.sync(&file)
    try phone.sync(&file)
    let phoneMovie = try #require(phone.library.movie(tmdbID: movie.tmdbID))

    // Different fields changed on each side between syncs.
    mac.library.setRating(movie, 8)
    phone.library.setFavorite(phoneMovie, true)
    phone.library.addNote("From the phone", to: phoneMovie)
    try mac.sync(&file)
    try phone.sync(&file)
    try mac.sync(&file)
    for movie in [movie, phoneMovie] {
        #expect(movie.userRating == 8 && movie.isFavorite)
        #expect(movie.notes?.map(\.text) == ["From the phone"])
    }

    // Nothing changed since: syncing again saves nothing on either side.
    #expect(try mac.sync(&file) == false)
    #expect(try phone.sync(&file) == false)
}

@MainActor @Test func syncMergesTagsWithTheSameNameAndCarriesCollections() throws {
    let mac = try SyncDevice(), phone = try SyncDevice()
    var file: LibraryBackup?
    let movie = mac.library.insertMovie(try fixture("movie_inception"))
    let macTag = try #require(mac.library.createTag(name: "Rewatch"))
    mac.library.toggle(macTag, on: .movie(movie))
    let phoneTag = try #require(phone.library.createTag(name: "rewatch"))
    var rules = SmartListRules()
    rules.tagIDs = [phoneTag.uuid]
    phone.library.createSmartList(name: "Rewatches", rules: rules)
    let space = try #require(mac.library.createSpace(name: "Mind Benders", symbolName: "brain", colorName: "purple"))

    try mac.sync(&file)
    try phone.sync(&file)
    try mac.sync(&file)
    // One tag on each device, with the same ID, so the file stops changing.
    let tagID = min(macTag.uuid.uuidString, phoneTag.uuid.uuidString)
    for library in [mac.library, phone.library] {
        let tags = try library.context.fetch(FetchDescriptor<MediaTag>())
        #expect(tags.map(\.uuid.uuidString) == [tagID])
        let list = try #require(try library.context.fetch(FetchDescriptor<SmartList>()).first)
        #expect(list.rules.tagIDs.map(\.uuidString) == [tagID])
        #expect(list.rules.matches(try #require(library.movie(tmdbID: movie.tmdbID))))
    }
    #expect(try mac.sync(&file) == false && phone.sync(&file) == false)

    // Deleting a space on one device deletes it on the other.
    phone.library.delete(try #require(phone.library.space(uuid: space.uuid)))
    try phone.sync(&file)
    try mac.sync(&file)
    #expect(try mac.library.context.fetchCount(FetchDescriptor<Space>()) == 0)
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

/// Answers every request with 401, like TMDB with a revoked token.
private final class UnauthorizedProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"status_message":"Invalid API key"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor @Test func listImportReportsFailedRequestsApartFromNotFound() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [UnauthorizedProtocol.self]
    let client = TMDBClient(token: "revoked", language: "en-US", session: URLSession(configuration: configuration))
    let library = LibraryService(context: try makeLibrary().context, client: client)

    let result = try await library.importList(ListImport.parse("Arrival (2016)\nTV SHOWS\nSeverance"), mark: .none)
    #expect(result.notFound.isEmpty)
    #expect(result.failed.map(\.label) == ["Arrival (2016)", "Severance"])
    #expect(result.failureReason?.contains("401") == true)
    #expect(try library.context.fetchCount(FetchDescriptor<Movie>()) == 0)
}

@Test func parsesWindowsTitleLists() {
    // UTF-16 with a byte-order mark and CRLF line endings, as Notepad saves "Unicode".
    let text = "TV SHOWS\r\nThe Sopranos (1999)\r\n\r\nSeverance (2022)\r\n"
    let data = Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!
    let entries = ListImport.parse(ListImport.decodeText(data))
    #expect(entries.map(\.label) == ["The Sopranos (1999)", "Severance (2022)"])
    #expect(entries.map(\.kind) == [.show, .show])
    #expect(entries.map(\.line) == [2, 4])
    #expect(ListImport.parse("Blade Runner (1982) (Director's Cut)\nLa La Land (2016) musical").map(\.label)
        == ["Blade Runner (1982)", "La La Land (2016)"])
    // A UTF-8 byte-order mark doesn't hide the heading either.
    #expect(ListImport.parse("\u{FEFF}TV SHOWS\nSeverance (2022)").map(\.kind) == [.show])
}

@MainActor @Test func csvQuotesLoneLineBreaks() {
    #expect(LibraryService.csvField("Two\nLines") == "\"Two\nLines\"")
    #expect(LibraryService.csvField("Carriage\rReturn") == "\"Carriage\rReturn\"")
    #expect(LibraryService.csvField("Plain") == "Plain")
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

// MARK: - Seerr

@Test func normalizesSeerrServerAddresses() {
    #expect(SeerrClient.normalizedURL("192.168.1.10:5055")?.absoluteString == "http://192.168.1.10:5055")
    #expect(SeerrClient.normalizedURL(" https://requests.example.com/ ")?.absoluteString == "https://requests.example.com")
    #expect(SeerrClient.normalizedURL("http://nas.local:5055/api/v1/")?.absoluteString == "http://nas.local:5055")
    #expect(SeerrClient.normalizedURL("https://example.com/seerr")?.absoluteString == "https://example.com/seerr")
    #expect(SeerrClient.normalizedURL("nas.local:5055")?.absoluteString == "http://nas.local:5055")
    #expect(SeerrClient.normalizedURL("seerr:5055")?.absoluteString == "http://seerr:5055")
    #expect(SeerrClient.normalizedURL("requests.example.com")?.absoluteString == "https://requests.example.com")
    #expect(SeerrClient.normalizedURL("ftp://example.com") == nil)
    #expect(SeerrClient.normalizedURL("") == nil)
    #expect(SeerrClient(server: "http://nas.local:5055", apiKey: "  ") == nil)
}

@Test func readsSeerrSeasonAvailability() throws {
    let json = """
    {"id": 95396, "seasons": [
        {"seasonNumber": 0, "name": "Specials", "episodeCount": 3},
        {"seasonNumber": 1, "name": "Season 1", "episodeCount": 9},
        {"seasonNumber": 2, "name": "Season 2", "episodeCount": 10},
        {"seasonNumber": 3, "name": "Season 3", "episodeCount": 10},
        {"seasonNumber": 4, "name": "Season 4", "episodeCount": 10}],
     "mediaInfo": {"status": 4,
        "seasons": [{"seasonNumber": 1, "status": 5}, {"seasonNumber": 2, "status": 1}],
        "requests": [{"id": 12, "status": 1, "is4k": false, "seasons": [{"seasonNumber": 2}],
                      "requestedBy": {"id": 3, "jellyfinUsername": "mehdi"}},
                     {"id": 10, "status": 3, "is4k": false, "seasons": [{"seasonNumber": 3}]},
                     {"id": 11, "status": 1, "is4k": true, "seasons": [{"seasonNumber": 4}]}]}}
    """
    let title = SeerrTitle(try JSONDecoder().decode(SeerrDetailBody.self, from: Data(json.utf8)))
    #expect(title.availability == .partiallyAvailable)
    #expect(title.seasons.map(\.number) == [1, 2, 3, 4])
    #expect(title.seasons.map(\.availability) == [.available, .requested, .requestable, .requestable])
    #expect(title.requestableSeasons.map(\.number) == [3, 4])
    #expect(title.requests == [SeerrRequest(id: 12, isApproved: false, seasons: [2], requestedBy: "mehdi")])

    let available = SeerrTitle(try JSONDecoder().decode(SeerrDetailBody.self, from: Data(
        #"{"id": 1, "mediaInfo": {"status": 5, "mediaUrl": "http://nas.local:8096/web/#/details?id=abc"}}"#.utf8)))
    #expect(available.mediaURL?.host() == "nas.local")
    #expect(!available.isInProgress)

    let unknown = SeerrTitle(try JSONDecoder().decode(SeerrDetailBody.self, from: Data(#"{"id": 1}"#.utf8)))
    #expect(unknown.availability == .requestable)
    #expect(unknown.seasons.isEmpty)
}

/// Records the request and answers 201, like Seerr accepting it.
private final class SeerrRecordingProtocol: URLProtocol {
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            return data
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"id": 7, "status": 1}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func sendsSeerrRequests() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SeerrRecordingProtocol.self]
    let client = try #require(SeerrClient(server: "nas.local:5055/", apiKey: "secret",
                                          session: URLSession(configuration: configuration)))
    try await client.request(.tv, tmdbID: 95396, seasons: [3, 1])

    let request = try #require(SeerrRecordingProtocol.lastRequest)
    #expect(request.url?.absoluteString == "http://nas.local:5055/api/v1/request")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "X-Api-Key") == "secret")
    let body = try #require(SeerrRecordingProtocol.lastBody)
    let sent = try JSONSerialization.jsonObject(with: body) as? [String: Any]
    #expect(sent?["mediaType"] as? String == "tv")
    #expect(sent?["mediaId"] as? Int == 95396)
    #expect(sent?["seasons"] as? [Int] == [1, 3])
}

/// Signs in any Jellyfin account, then expects its session cookie on every later request.
private final class SeerrSignInProtocol: URLProtocol {
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        let path = request.url!.path()
        let signedIn = request.value(forHTTPHeaderField: "Cookie") == "connect.sid=s%3Aabc.def"
        let (status, headers, body): (Int, [String: String], String) = switch path {
        case "/api/v1/auth/jellyfin":
            (200, ["Set-Cookie": "connect.sid=s%3Aabc.def; Path=/; Expires=Fri, 06 Nov 2026 10:00:00 GMT; HttpOnly"],
             #"{"id": 3, "jellyfinUsername": "mehdi", "displayName": ""}"#)
        case "/api/v1/auth/me" where signedIn: (200, [:], #"{"id": 3, "jellyfinUsername": "mehdi"}"#)
        case "/api/v1/request/7" where signedIn && request.httpMethod == "DELETE": (204, [:], "")
        default: (403, [:], #"{"message": "You do not have permission to access this endpoint."}"#)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func signsInToSeerrWithJellyfin() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SeerrSignInProtocol.self]
    configuration.httpCookieStorage = nil
    let session = URLSession(configuration: configuration)

    let (client, user) = try await SeerrClient.signIn(server: "nas.local:5055", with: .jellyfin(username: "mehdi", password: "pw"),
                                                      session: session)
    #expect(user.name == "mehdi")
    #expect(client.auth == .session("s%3Aabc.def"))
    #expect(try await client.currentUser().id == 3)
    #expect(SeerrSignInProtocol.lastRequest?.value(forHTTPHeaderField: "X-Api-Key") == nil)

    // An expired session reads as signed out, not as a missing permission.
    let expired = try #require(SeerrClient(server: "nas.local:5055", auth: .session("old"), session: session))
    do { _ = try await expired.currentUser() } catch SeerrError.unauthorized {} catch { Issue.record("\(error)") }

    // Deleting: 204 with no body; someone else's request is refused without signing out.
    try await client.deleteRequest(id: 7)
    do {
        try await client.deleteRequest(id: 8)
        Issue.record("Expected a refusal")
    } catch let SeerrError.http(status, message) {
        #expect(status == 403)
        #expect(message?.contains("permission") == true)
    }
    do { try await expired.deleteRequest(id: 7) } catch SeerrError.unauthorized {} catch { Issue.record("\(error)") }
}
