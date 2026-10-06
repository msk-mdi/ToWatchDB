import Foundation
import SwiftData

/// All library mutations go through here so watch-state rules live in one place.
@MainActor
public struct LibraryService {
    public let context: ModelContext
    public let client: TMDBClient?

    public init(context: ModelContext, client: TMDBClient?) {
        self.context = context
        self.client = client
    }

    private func requireClient() throws -> TMDBClient {
        guard let client else { throw TMDBError.missingToken }
        return client
    }

    // MARK: Lookup

    public func movie(tmdbID: Int) -> Movie? {
        var descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.tmdbID == tmdbID })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    public func show(tmdbID: Int) -> TVShow? {
        var descriptor = FetchDescriptor<TVShow>(predicate: #Predicate { $0.tmdbID == tmdbID })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    // MARK: Adding

    /// Adds a movie from TMDB, or returns the existing one.
    @discardableResult
    public func addMovie(tmdbID: Int) async throws -> Movie {
        if let existing = movie(tmdbID: tmdbID) { return existing }
        let detail = try await requireClient().movie(id: tmdbID)
        return insertMovie(detail)
    }

    /// Adds a TV show with all of its seasons and episodes, or returns the existing one.
    @discardableResult
    public func addShow(tmdbID: Int) async throws -> TVShow {
        if let existing = show(tmdbID: tmdbID) { return existing }
        let (detail, seasons) = try await requireClient().tvShowWithSeasons(id: tmdbID)
        return insertShow(detail, seasons: seasons)
    }

    /// Inserts (or updates) a movie from an already-fetched TMDB payload.
    @discardableResult
    public func insertMovie(_ detail: TMDBMovieDetail) -> Movie {
        // Re-check: another add may have finished while this one was awaiting the network.
        let movie = movie(tmdbID: detail.id) ?? {
            let movie = Movie(tmdbID: detail.id, title: detail.title)
            context.insert(movie)
            return movie
        }()
        movie.apply(detail)
        save()
        return movie
    }

    /// Inserts (or updates) a show from already-fetched TMDB payloads.
    @discardableResult
    public func insertShow(_ detail: TMDBTVDetail, seasons: [TMDBSeasonDetail]) -> TVShow {
        let show = show(tmdbID: detail.id) ?? {
            let show = TVShow(tmdbID: detail.id, name: detail.name)
            context.insert(show)
            return show
        }()
        show.apply(detail)
        merge(seasons, into: show)
        save()
        return show
    }

    // MARK: Refreshing

    public func refresh(_ movie: Movie) async throws {
        let detail = try await requireClient().movie(id: movie.tmdbID)
        movie.apply(detail)
        save()
    }

    public func refresh(_ show: TVShow) async throws {
        let (detail, seasons) = try await requireClient().tvShowWithSeasons(id: show.tmdbID)
        show.apply(detail)
        merge(seasons, into: show)
        save()
    }

    /// Refreshes ongoing shows and unreleased movies that haven't been refreshed within `maxAge`.
    /// Failures are skipped so one bad item doesn't block the rest; returns how many were refreshed.
    @discardableResult
    public func refreshStale(maxAge: TimeInterval = 12 * 3600, now: Date = .now) async -> Int {
        let isStale: (Date?) -> Bool = { $0.map { now.timeIntervalSince($0) > maxAge } ?? true }
        let shows = ((try? context.fetch(FetchDescriptor<TVShow>())) ?? [])
            .filter { $0.isOngoing && !$0.isAbandoned && isStale($0.lastRefreshed) }
        let movies = ((try? context.fetch(FetchDescriptor<Movie>())) ?? [])
            .filter { !$0.isReleased(asOf: now) && isStale($0.lastRefreshed) }

        guard let client, !shows.isEmpty || !movies.isEmpty else { return 0 }

        // A few titles download at a time (a show's seasons already download in parallel), and the library is
        // saved once at the end: every save redraws each open page, so saving per title made a refresh of
        // many shows keep the main thread busy.
        let showsByID = Dictionary(shows.map { ($0.tmdbID, $0) }) { first, _ in first }
        let moviesByID = Dictionary(movies.map { ($0.tmdbID, $0) }) { first, _ in first }
        var count = 0
        await Self.forEachConcurrently(Array(showsByID.keys), limit: 4) {
            try? await client.tvShowWithSeasons(id: $0)
        } apply: { id, payload in
            guard let (detail, seasons) = payload, let show = showsByID[id] else { return }
            show.apply(detail)
            merge(seasons, into: show)
            count += 1
        }
        await Self.forEachConcurrently(Array(moviesByID.keys), limit: 4) {
            try? await client.movie(id: $0)
        } apply: { id, detail in
            guard let detail, let movie = moviesByID[id] else { return }
            movie.apply(detail)
            count += 1
        }
        if count > 0 { save() }
        return count
    }

    /// Runs `fetch` for each ID with at most `limit` running at once, and hands each result to `apply` on the
    /// main actor as it arrives.
    private static func forEachConcurrently<Value: Sendable>(
        _ ids: [Int], limit: Int,
        fetch: @escaping @Sendable (Int) async -> Value,
        apply: (Int, Value) -> Void
    ) async {
        await withTaskGroup(of: (Int, Value).self) { group in
            var pending = ids.makeIterator()
            func startNext() {
                guard let id = pending.next() else { return }
                group.addTask { (id, await fetch(id)) }
            }
            for _ in 0..<limit { startNext() }
            while let (id, value) = await group.next() {
                apply(id, value)
                startNext()
            }
        }
    }

    /// Upserts seasons and episodes by number, keeping the user's watch data.
    func merge(_ seasonDetails: [TMDBSeasonDetail], into show: TVShow) {
        var existingSeasons = Dictionary((show.seasons ?? []).map { ($0.seasonNumber, $0) }) { first, _ in first }
        for detail in seasonDetails {
            let season = existingSeasons[detail.seasonNumber] ?? {
                let season = Season(tmdbID: detail.id, seasonNumber: detail.seasonNumber)
                context.insert(season)
                season.show = show
                existingSeasons[detail.seasonNumber] = season
                return season
            }()
            season.apply(detail)

            var existingEpisodes = Dictionary((season.episodes ?? []).map { ($0.episodeNumber, $0) }) { first, _ in first }
            for episodeDetail in detail.episodes {
                let episode = existingEpisodes[episodeDetail.episodeNumber] ?? {
                    let episode = Episode(tmdbID: episodeDetail.id, seasonNumber: detail.seasonNumber, episodeNumber: episodeDetail.episodeNumber)
                    context.insert(episode)
                    episode.season = season
                    existingEpisodes[episodeDetail.episodeNumber] = episode
                    return episode
                }()
                episode.apply(episodeDetail)
            }
        }
    }

    // MARK: Watch state

    public func setWatched(_ movie: Movie, _ watched: Bool, on date: Date? = .now) {
        movie.isWatched = watched
        movie.watchedDate = watched ? date : nil
        if watched { movie.isInBacklog = false }
        save()
    }

    public func setWatched(_ episode: Episode, _ watched: Bool, on date: Date? = .now) {
        episode.isWatched = watched
        episode.watchedDate = watched ? date : nil
        if watched, let show = episode.show {
            show.isInBacklog = false
            show.isAbandoned = false
        }
        save()
    }

    /// Marks every aired episode of the season watched (or all of them unwatched).
    public func setWatched(_ season: Season, _ watched: Bool, on date: Date? = .now, now: Date = .now) {
        let episodes = watched ? season.airedEpisodes(asOf: now) : season.sortedEpisodes
        mark(episodes, watched: watched, on: date, show: season.show)
    }

    /// Marks every aired regular episode of the show watched (or every episode unwatched).
    public func setWatched(_ show: TVShow, _ watched: Bool, on date: Date? = .now, now: Date = .now) {
        let episodes = watched ? show.airedEpisodes(asOf: now) : show.sortedSeasons.flatMap(\.sortedEpisodes)
        mark(episodes, watched: watched, on: date, show: show)
    }

    /// Marks this episode and every aired regular episode before it as watched.
    public func markWatchedUpTo(_ episode: Episode, on date: Date? = .now, now: Date = .now) {
        guard let show = episode.show else { return setWatched(episode, true, on: date) }
        let ordered = show.regularEpisodes
        guard let index = ordered.firstIndex(where: { $0.persistentModelID == episode.persistentModelID }) else {
            return setWatched(episode, true, on: date)
        }
        let earlier = ordered[...index].filter { $0.hasAired(asOf: now) || $0.persistentModelID == episode.persistentModelID }
        mark(Array(earlier), watched: true, on: date, show: show)
    }

    private func mark(_ episodes: [Episode], watched: Bool, on date: Date?, show: TVShow?) {
        for episode in episodes where episode.isWatched != watched {
            episode.isWatched = watched
            episode.watchedDate = watched ? date : nil
        }
        if watched, let show {
            show.isInBacklog = false
            show.isAbandoned = false
        }
        save()
    }

    // MARK: Lists, ratings, notes

    public func setBacklog(_ movie: Movie, _ value: Bool) { movie.isInBacklog = value; save() }
    public func setBacklog(_ show: TVShow, _ value: Bool) { show.isInBacklog = value; save() }
    public func setFavorite(_ movie: Movie, _ value: Bool) { movie.isFavorite = value; save() }
    public func setFavorite(_ show: TVShow, _ value: Bool) { show.isFavorite = value; save() }
    public func setAbandoned(_ show: TVShow, _ value: Bool) { show.isAbandoned = value; save() }

    /// Ratings are 0–10; `nil` clears.
    public func setRating(_ movie: Movie, _ rating: Double?) { movie.userRating = rating.map(Self.clampRating); save() }
    public func setRating(_ show: TVShow, _ rating: Double?) { show.userRating = rating.map(Self.clampRating); save() }
    public func setRating(_ episode: Episode, _ rating: Double?) { episode.userRating = rating.map(Self.clampRating); save() }

    static func clampRating(_ value: Double) -> Double { min(max(value, 0), 10) }

    @discardableResult
    public func addNote(_ text: String, to movie: Movie) -> Note? { insertNote(text) { $0.movie = movie } }
    @discardableResult
    public func addNote(_ text: String, to show: TVShow) -> Note? { insertNote(text) { $0.show = show } }
    @discardableResult
    public func addNote(_ text: String, to episode: Episode) -> Note? { insertNote(text) { $0.episode = episode } }

    private func insertNote(_ text: String, attach: (Note) -> Void) -> Note? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let note = Note(text: trimmed)
        context.insert(note)
        attach(note)
        save()
        return note
    }

    public func update(_ note: Note, text: String) {
        note.text = text
        note.updatedAt = .now
        save()
    }

    public func delete(_ model: some PersistentModel) {
        context.delete(model)
        save()
    }

    public func save() {
        do { try context.save() } catch { assertionFailure("SwiftData save failed: \(error)") }
    }
}

// MARK: - Mapping TMDB payloads onto models

extension Movie {
    func apply(_ detail: TMDBMovieDetail) {
        title = detail.title
        originalTitle = detail.originalTitle
        overview = detail.overview
        tagline = detail.tagline.flatMap { $0.isEmpty ? nil : $0 }
        posterPath = detail.posterPath
        backdropPath = detail.backdropPath
        releaseDate = TMDBDate.parse(detail.releaseDate)
        runtime = detail.runtime.flatMap { $0 > 0 ? $0 : nil }
        genres = detail.genres?.map(\.name) ?? []
        releaseStatus = detail.status
        voteAverage = detail.voteAverage
        imdbID = detail.imdbId
        homepage = detail.homepage.flatMap { $0.isEmpty ? nil : $0 }
        trailerKey = detail.videos?.bestTrailerKey
        castData = PersonCredit.encode(PersonCredit.cast(from: detail.credits))
        directorsData = PersonCredit.encode(
            (detail.credits?.crew ?? []).filter { $0.job == "Director" }
                .map { PersonCredit(id: $0.id, name: $0.name, role: $0.job, profilePath: $0.profilePath) }
        )
        lastRefreshed = .now
    }
}

extension TVShow {
    func apply(_ detail: TMDBTVDetail) {
        name = detail.name
        originalName = detail.originalName
        overview = detail.overview
        tagline = detail.tagline.flatMap { $0.isEmpty ? nil : $0 }
        posterPath = detail.posterPath
        backdropPath = detail.backdropPath
        firstAirDate = TMDBDate.parse(detail.firstAirDate)
        lastAirDate = TMDBDate.parse(detail.lastAirDate)
        showStatus = detail.status
        genres = detail.genres?.map(\.name) ?? []
        networks = detail.networks?.map(\.name) ?? []
        numberOfSeasons = detail.numberOfSeasons
        numberOfEpisodes = detail.numberOfEpisodes
        episodeRuntime = detail.episodeRunTime?.first
        voteAverage = detail.voteAverage
        homepage = detail.homepage.flatMap { $0.isEmpty ? nil : $0 }
        trailerKey = detail.videos?.bestTrailerKey
        castData = PersonCredit.encode(PersonCredit.cast(from: detail.credits))
        creatorsData = PersonCredit.encode(
            (detail.createdBy ?? []).map { PersonCredit(id: $0.id, name: $0.name, role: "Creator", profilePath: $0.profilePath) }
        )
        lastRefreshed = .now
    }
}

extension Season {
    func apply(_ detail: TMDBSeasonDetail) {
        update(\.tmdbID, detail.id)
        update(\.name, detail.name)
        update(\.overview, detail.overview)
        update(\.posterPath, detail.posterPath)
        update(\.airDate, TMDBDate.parse(detail.airDate))
    }
}

extension Episode {
    /// Writes only the fields that changed. A refresh re-applies every episode of a show, and each write
    /// marks the episode as changed, so unchanged episodes would otherwise all be saved again.
    func apply(_ detail: TMDBEpisode) {
        update(\.tmdbID, detail.id)
        update(\.name, detail.name)
        update(\.overview, detail.overview)
        update(\.airDate, TMDBDate.parse(detail.airDate))
        update(\.runtime, detail.runtime)
        update(\.stillPath, detail.stillPath)
    }
}

extension PersistentModel {
    /// Assigns only when the value differs, so an unchanged field doesn't mark the model as changed.
    fileprivate func update<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<Self, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }
}

extension PersonCredit {
    public static func cast(from credits: TMDBCredits?, limit: Int = 20) -> [PersonCredit] {
        (credits?.cast ?? [])
            .sorted { ($0.order ?? .max) < ($1.order ?? .max) }
            .prefix(limit)
            .map { PersonCredit(id: $0.id, name: $0.name, role: $0.character, profilePath: $0.profilePath) }
    }
}
