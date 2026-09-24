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

    library.setAbandoned(show, true)
    #expect(UpcomingService.upcomingEpisodes([show], now: now).isEmpty)
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
