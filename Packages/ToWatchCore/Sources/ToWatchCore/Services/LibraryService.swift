import Foundation
import SwiftData

/// All library mutations go through here so watch-state rules live in one place.
@MainActor
public struct LibraryService {
    public let context: ModelContext
    public let client: TMDBClient?
    /// Where IMDb ratings come from; `nil` leaves them alone (tests, which mustn't reach the network).
    public let imdb: IMDbClient?

    public init(context: ModelContext, client: TMDBClient?, imdb: IMDbClient? = nil) {
        self.context = context
        self.client = client
        self.imdb = imdb
    }

    func requireClient() throws -> TMDBClient {
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
        let movie = insertMovie(detail)
        refreshIMDbRatingsLater(movies: [movie])
        return movie
    }

    /// Adds a TV show with all of its seasons and episodes, or returns the existing one.
    @discardableResult
    public func addShow(tmdbID: Int) async throws -> TVShow {
        if let existing = show(tmdbID: tmdbID) { return existing }
        let (detail, seasons) = try await requireClient().tvShowWithSeasons(id: tmdbID)
        let show = insertShow(detail, seasons: seasons)
        refreshIMDbRatingsLater(shows: [show])
        return show
    }

    /// Adds a show whose detail was already fetched (a preview page): only its seasons are downloaded.
    @discardableResult
    public func addShow(_ detail: TMDBTVDetail) async throws -> TVShow {
        if let existing = show(tmdbID: detail.id) { return existing }
        let seasons = try await requireClient().seasons(of: detail)
        let show = insertShow(detail, seasons: seasons)
        refreshIMDbRatingsLater(shows: [show])
        return show
    }

    /// Inserts (or updates) a movie from an already-fetched TMDB payload.
    @discardableResult
    public func insertMovie(_ detail: TMDBMovieDetail) -> Movie {
        let movie = upsertMovie(detail)
        save()
        return movie
    }

    /// Inserts (or updates) a show from already-fetched TMDB payloads.
    @discardableResult
    public func insertShow(_ detail: TMDBTVDetail, seasons: [TMDBSeasonDetail]) -> TVShow {
        let show = upsertShow(detail, seasons: seasons)
        save()
        return show
    }

    /// `insertMovie` without saving, for batches that save once.
    func upsertMovie(_ detail: TMDBMovieDetail) -> Movie {
        // Re-check: another add may have finished while this one was awaiting the network.
        let movie = movie(tmdbID: detail.id) ?? {
            let movie = Movie(tmdbID: detail.id, title: detail.title)
            context.insert(movie)
            return movie
        }()
        movie.apply(detail)
        return movie
    }

    /// `insertShow` without saving, for batches that save once.
    func upsertShow(_ detail: TMDBTVDetail, seasons: [TMDBSeasonDetail]) -> TVShow {
        let show = show(tmdbID: detail.id) ?? {
            let show = TVShow(tmdbID: detail.id, name: detail.name)
            context.insert(show)
            return show
        }()
        show.apply(detail)
        merge(seasons, into: show)
        return show
    }

    // MARK: Refreshing

    public func refresh(_ movie: Movie) async throws {
        let detail = try await requireClient().movie(id: movie.tmdbID)
        guard movie.isLive else { return }
        movie.apply(detail)
        save()
        refreshIMDbRatingsLater(movies: [movie])
    }

    public func refresh(_ show: TVShow) async throws {
        let (detail, seasons) = try await requireClient().tvShowWithSeasons(id: show.tmdbID)
        guard show.isLive else { return }
        show.apply(detail)
        merge(seasons, into: show)
        save()
        refreshIMDbRatingsLater(shows: [show])
    }

    /// Refreshes ongoing shows and unreleased movies that haven't been refreshed within `maxAge`.
    /// Failures are skipped so one bad item doesn't block the rest; returns how many were refreshed. Throws when
    /// TMDB turns the token down, after saving what was refreshed: every other title would fail the same way,
    /// and a revoked token otherwise failed one request per title at every launch without a word.
    @discardableResult
    public func refreshStale(maxAge: TimeInterval = 12 * 3600, now: Date = .now) async throws -> Int {
        let isStale: (Date?) -> Bool = { $0.map { now.timeIntervalSince($0) > maxAge } ?? true }
        // The store narrows it down (this runs at every launch and activation); the checks after are exact.
        let cutoff = now.addingTimeInterval(-maxAge), today = TMDBDate.today(now)
        let shows = ((try? context.fetch(FetchDescriptor<TVShow>(predicate: #Predicate {
            !$0.isAbandoned && ($0.lastRefreshed == nil || $0.lastRefreshed! < cutoff)
        }))) ?? []).filter { $0.isOngoing && isStale($0.lastRefreshed) }
        let movies = ((try? context.fetch(FetchDescriptor<Movie>(predicate: #Predicate {
            ($0.releaseDate == nil || $0.releaseDate! > today) && ($0.lastRefreshed == nil || $0.lastRefreshed! < cutoff)
        }))) ?? []).filter { !$0.isReleased(asOf: now) && isStale($0.lastRefreshed) }

        guard let client, !shows.isEmpty || !movies.isEmpty else { return 0 }

        // A few titles download at a time (a show's seasons already download in parallel), and the library is
        // saved once at the end: every save redraws each open page, so saving per title made a refresh of
        // many shows keep the main thread busy.
        let showsByID = Dictionary(shows.map { ($0.tmdbID, $0) }) { first, _ in first }
        let moviesByID = Dictionary(movies.map { ($0.tmdbID, $0) }) { first, _ in first }
        var count = 0
        var rejection: (any Error)?
        await Self.forEachConcurrently(Array(showsByID.keys), limit: 4) { id in
            await Result { try await client.tvShowWithSeasons(id: id) }
        } apply: { id, result in
            rejection = rejection ?? Self.tokenRejection(in: result)
            // A title deleted while downloading (by the user or a sync) is skipped: writing to it can trap.
            guard let (detail, seasons) = try? result.get(), let show = showsByID[id], show.isLive else { return }
            show.apply(detail)
            merge(seasons, into: show)
            count += 1
        } until: { rejection != nil }
        if rejection == nil {
            await Self.forEachConcurrently(Array(moviesByID.keys), limit: 4) { id in
                await Result { try await client.movie(id: id) }
            } apply: { id, result in
                rejection = rejection ?? Self.tokenRejection(in: result)
                guard let detail = try? result.get(), let movie = moviesByID[id], movie.isLive else { return }
                movie.apply(detail)
                count += 1
            } until: { rejection != nil }
        }
        if count > 0 { save() }
        let failed = shows.count + movies.count - count
        Log.refresh.info("Refreshed \(count, privacy: .public) of \(shows.count, privacy: .public) shows and \(movies.count, privacy: .public) movies")
        if let rejection {
            Log.refresh.error("TMDB turned down the token: \(rejection.localizedDescription, privacy: .public)")
            throw rejection
        }
        if failed > 0 { Log.refresh.error("\(failed, privacy: .public) titles weren't refreshed (failed, or deleted meanwhile)") }
        return count
    }

    // MARK: IMDb ratings

    /// Fetches IMDb ratings for library titles whose rating is older than `maxAge` (or was never fetched).
    /// Ratings change slowly, so this runs far less often than `refreshStale`. A rating that came from a backup
    /// or the sync file is kept until it's `importedMaxAge` old, so restoring or syncing doesn't ask IMDb again.
    @discardableResult
    public func refreshStaleIMDbRatings(maxAge: TimeInterval = 3 * 86400, importedMaxAge: TimeInterval = 7 * 86400,
                                        now: Date = .now) async -> Int {
        let isStale: (any IMDbRated) -> Bool = { title in
            title.imdbRatingDate.map { now.timeIntervalSince($0) > (title.imdbRatingIsImported ? importedMaxAge : maxAge) } ?? true
        }
        // The store narrows it down to ratings older than the shorter age; `isStale` is exact.
        let cutoff = now.addingTimeInterval(-min(maxAge, importedMaxAge))
        let movies = ((try? context.fetch(FetchDescriptor<Movie>(predicate: #Predicate {
            $0.imdbID != nil && ($0.imdbRatingDate == nil || $0.imdbRatingDate! < cutoff)
        }))) ?? []).filter(isStale)
        let allShows = ((try? context.fetch(FetchDescriptor<TVShow>(predicate: #Predicate {
            $0.imdbRatingDate == nil || $0.imdbRatingDate! < cutoff
        }))) ?? []).filter(isStale)
        await lookUpIMDbIDs(allShows.filter { $0.imdbID == nil }, now: now)
        // The lookup awaited the network: a title deleted meanwhile (by the user or a sync) can't be read.
        let shows = allShows.filter { $0.isLive && $0.imdbID != nil }
        return await refreshIMDbRatings(movies: movies.filter(\.isLive), shows: shows, now: now)
    }

    /// Fetches an opened movie's IMDb rating when it was never fetched or it's older than `maxAge`.
    public func refreshIMDbRatingIfDue(_ movie: Movie, maxAge: TimeInterval = 86400, now: Date = .now) async {
        guard imdb != nil, movie.isLive, Self.isIMDbRatingDue(movie, maxAge: maxAge, now: now) else { return }
        await refreshIMDbRatings(movies: [movie], now: now)
    }

    /// Fetches an opened show's IMDb rating when it was never fetched or it's older than `maxAge`, looking up its IMDb
    /// ID first if it doesn't have one yet.
    public func refreshIMDbRatingIfDue(_ show: TVShow, maxAge: TimeInterval = 86400, now: Date = .now) async {
        guard imdb != nil, show.isLive, Self.isIMDbRatingDue(show, maxAge: maxAge, now: now) else { return }
        if show.imdbID == nil { await lookUpIMDbIDs([show], now: now) }
        guard show.isLive, show.imdbID != nil else { return }
        await refreshIMDbRatings(shows: [show], now: now)
    }

    /// By date alone: a title OMDb (or TMDB) has no rating for keeps none, and was asked again at every opening.
    static func isIMDbRatingDue(_ title: some IMDbRated, maxAge: TimeInterval, now: Date) -> Bool {
        title.imdbRatingDate.map { now.timeIntervalSince($0) > maxAge } ?? true
    }

    /// A show gets its IMDb ID from a full refresh, and only ongoing shows are refreshed on their own, so
    /// shows that had ended when they were added (or came from an older backup) look theirs up here.
    private func lookUpIMDbIDs(_ shows: [TVShow], now: Date) async {
        guard let client, !shows.isEmpty else { return }
        let showsByID = Dictionary(shows.map { ($0.tmdbID, $0) }) { first, _ in first }
        var changed = false
        var isRejected = false
        await Self.forEachConcurrently(Array(showsByID.keys), limit: 4) { id in
            await Result { try await client.tvExternalIDs(id: id) }
        } apply: { id, result in
            if Self.tokenRejection(in: result) != nil { isRejected = true }
            guard let ids = try? result.get(), let show = showsByID[id], show.isLive else { return }
            if let imdbID = ids.imdbId, !imdbID.isEmpty {
                show.imdbID = imdbID
            } else {
                show.imdbRatingDate = now // TMDB has none: don't ask again until the ratings are due.
            }
            changed = true
        } until: { isRejected }
        if changed { save() }
    }

    /// The error, if TMDB turned the token down (a wrong or revoked one): every other request would fail too.
    static func tokenRejection<T>(in result: Result<T, any Error>) -> (any Error)? {
        switch result {
        case let .failure(error as TMDBError):
            switch error {
            case .http(status: 401, _), .missingToken: error
            default: nil
            }
        default: nil
        }
    }

    /// Fetches the IMDb ratings of these titles and saves once. A failed request leaves
    /// the ratings as they were; returns how many titles were updated.
    @discardableResult
    public func refreshIMDbRatings(movies: [Movie] = [], shows: [TVShow] = [], now: Date = .now) async -> Int {
        // Deleted before this ran (it can be started without waiting, see `refreshIMDbRatingsLater`): can't be read.
        let ids = movies.filter(\.isLive).compactMap(\.imdbID) + shows.filter(\.isLive).compactMap(\.imdbID)
        guard let imdb, !ids.isEmpty else { return 0 }
        let ratings: [String: IMDbRating?]
        do { ratings = try await imdb.ratings(for: ids) } catch {
            // Not the error itself: a URL error carries the request's URL, which holds the OMDb key.
            Log.refresh.error("No IMDb ratings came back for \(ids.count, privacy: .public) titles (\(String(describing: type(of: error)), privacy: .public))")
            return 0
        }
        var count = 0
        // Titles deleted while the request ran (by the user or a sync) are skipped: writing to them can trap.
        // Titles IMDb didn't answer for keep their rating and date, so they're asked for again next time.
        for movie in movies where movie.isLive {
            guard let id = movie.imdbID, let rating = ratings[id] else { continue }
            movie.applyIMDbRating(rating, on: now)
            count += 1
        }
        for show in shows where show.isLive {
            guard let id = show.imdbID, let rating = ratings[id] else { continue }
            show.applyIMDbRating(rating, on: now)
            count += 1
        }
        if count > 0 { save() }
        return count
    }

    /// `refreshIMDbRatings` without waiting for it. Adding or refreshing a title used to wait on the ratings,
    /// so a slow answer kept the Add button spinning after the title was already saved.
    public func refreshIMDbRatingsLater(movies: [Movie] = [], shows: [TVShow] = []) {
        guard imdb != nil else { return }
        Task { await refreshIMDbRatings(movies: movies, shows: shows) }
    }

    /// Runs `fetch` for each ID with at most `limit` running at once, and hands each result to `apply` on the
    /// main actor as it arrives. Once `stop` returns true, no more are started and the ones running are cancelled.
    static func forEachConcurrently<Value: Sendable>(
        _ ids: [Int], limit: Int,
        fetch: @escaping @Sendable (Int) async -> Value,
        apply: (Int, Value) -> Void,
        until stop: () -> Bool = { false }
    ) async {
        await withTaskGroup(of: (Int, Value).self) { group in
            // Children are added inline rather than from a local function capturing `group`: the launch refresh
            // crashed in the runtime as a child finished into its group.
            var pending = ids.makeIterator()
            for _ in 0..<limit {
                guard let id = pending.next() else { break }
                group.addTask { (id, await fetch(id)) }
            }
            while let (id, value) = await group.next() {
                apply(id, value)
                if stop() {
                    group.cancelAll()
                    continue
                }
                if let next = pending.next() {
                    group.addTask { (next, await fetch(next)) }
                }
            }
        }
    }

    /// Upserts seasons and episodes by number, keeping the user's watch data. `seasonDetails` is the show's full
    /// list (`TMDBClient.seasons` fails as a whole), so episodes and seasons TMDB no longer lists are removed:
    /// a dropped placeholder kept a show on Watching with a phantom next episode. Ones holding the user's data
    /// (watched, rated, or with notes) stay.
    func merge(_ seasonDetails: [TMDBSeasonDetail], into show: TVShow) {
        removeEpisodes(missingFrom: seasonDetails, in: show)
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

    private func removeEpisodes(missingFrom seasonDetails: [TMDBSeasonDetail], in show: TVShow) {
        let listed = Dictionary(seasonDetails.map { ($0.seasonNumber, Set($0.episodes.map(\.episodeNumber))) }) { first, _ in first }
        for season in show.seasons ?? [] {
            let episodes = listed[season.seasonNumber]
            for episode in season.episodes ?? [] where episodes?.contains(episode.episodeNumber) != true {
                guard !episode.isWatched, episode.userRating == nil, episode.notes?.isEmpty ?? true else { continue }
                context.delete(episode)
            }
            if episodes == nil, (season.episodes ?? []).allSatisfy(\.isDeleted) { context.delete(season) }
        }
    }

    // MARK: Watch state
    // Setters skip a model deleted meanwhile (by a sync, or a refresh dropping an episode): a view or menu can
    // still hold it, and writing to a deleted model can trap.

    public func setWatched(_ movie: Movie, _ watched: Bool, on date: Date? = .now) {
        guard movie.isLive else { return }
        movie.isWatched = watched
        movie.watchedDate = watched ? date : nil
        if watched { movie.isInBacklog = false }
        save()
    }

    public func setWatched(_ episode: Episode, _ watched: Bool, on date: Date? = .now) {
        guard episode.isLive else { return }
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
        guard season.isLive else { return }
        let episodes = watched ? season.airedEpisodes(asOf: now) : season.sortedEpisodes
        mark(episodes, watched: watched, on: date, show: season.show)
    }

    /// Marks every aired regular episode of the show watched (or every episode unwatched).
    public func setWatched(_ show: TVShow, _ watched: Bool, on date: Date? = .now, now: Date = .now) {
        guard show.isLive else { return }
        let episodes = watched ? show.airedEpisodes(asOf: now) : show.sortedSeasons.flatMap(\.sortedEpisodes)
        mark(episodes, watched: watched, on: date, show: show)
    }

    /// Marks this episode and every aired regular episode before it as watched.
    public func markWatchedUpTo(_ episode: Episode, on date: Date? = .now, now: Date = .now) {
        guard episode.isLive else { return }
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

    public func setBacklog(_ movie: Movie, _ value: Bool) { set(movie, \.isInBacklog, value) }
    public func setBacklog(_ show: TVShow, _ value: Bool) { set(show, \.isInBacklog, value) }
    public func setFavorite(_ movie: Movie, _ value: Bool) { set(movie, \.isFavorite, value) }
    public func setFavorite(_ show: TVShow, _ value: Bool) { set(show, \.isFavorite, value) }
    public func setAbandoned(_ show: TVShow, _ value: Bool) { set(show, \.isAbandoned, value) }

    /// Ratings are 0–10; `nil` clears.
    public func setRating(_ movie: Movie, _ rating: Double?) { set(movie, \.userRating, rating.map(Self.clampRating)) }
    public func setRating(_ show: TVShow, _ rating: Double?) { set(show, \.userRating, rating.map(Self.clampRating)) }
    public func setRating(_ episode: Episode, _ rating: Double?) { set(episode, \.userRating, rating.map(Self.clampRating)) }

    private func set<M: PersistentModel, T>(_ model: M, _ keyPath: ReferenceWritableKeyPath<M, T>, _ value: T) {
        guard model.isLive else { return }
        model[keyPath: keyPath] = value
        save()
    }

    static func clampRating(_ value: Double) -> Double { min(max(value, 0), 10) }

    @discardableResult
    public func addNote(_ text: String, to movie: Movie) -> Note? {
        movie.isLive ? insertNote(text) { $0.movie = movie } : nil
    }
    @discardableResult
    public func addNote(_ text: String, to show: TVShow) -> Note? {
        show.isLive ? insertNote(text) { $0.show = show } : nil
    }
    @discardableResult
    public func addNote(_ text: String, to episode: Episode) -> Note? {
        episode.isLive ? insertNote(text) { $0.episode = episode } : nil
    }

    private func insertNote(_ text: String, attach: (Note) -> Void) -> Note? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let note = Note(text: trimmed) // With its own ID: two notes from one second stay apart in sync.
        context.insert(note)
        attach(note)
        save()
        return note
    }

    /// Gives an ID to each older note that shares one with another note of its title or episode: two from one
    /// second, which an import could add. Sync kept only one of them.
    public func separateNotesSharingAnID() {
        struct Key: Hashable {
            let owner: PersistentIdentifier?
            let id: UUID
        }
        guard let notes = try? context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.uuid == nil })) else { return }
        var seen = Set<Key>()
        var changed = false
        for note in notes.sorted(by: { $0.createdAt < $1.createdAt }) {
            let owner = note.movie?.persistentModelID ?? note.show?.persistentModelID ?? note.episode?.persistentModelID
            guard !seen.insert(Key(owner: owner, id: note.noteID)).inserted else { continue }
            note.uuid = UUID()
            changed = true
        }
        if changed { save() }
    }

    public func update(_ note: Note, text: String) {
        guard note.isLive else { return }
        note.text = text
        note.updatedAt = .now
        save()
    }

    public func delete(_ model: some PersistentModel) {
        guard model.isLive else { return }
        context.delete(model)
        save()
    }

    /// Saves for an edit the UI can't report. A failed save is rolled back: left pending, its changes were saved
    /// later with an unrelated edit, or made every later save fail too. It's logged and handed to
    /// `saveFailed`: in Release, a tap that was undone used to look like it had worked.
    @discardableResult
    public func save() -> Bool {
        do {
            try commit()
            return true
        } catch {
            Log.library.error("Save failed and was rolled back: \(error.localizedDescription, privacy: .public)")
            Self.saveFailed?(error)
            return false
        }
    }

    /// Told about every save that failed and was rolled back. The app shows it.
    public static var saveFailed: ((any Error) -> Void)?

    /// Saves, rolling back the unsaved changes if that fails, for callers that must not go on as if it worked.
    public func commit() throws {
        do { try context.save() } catch {
            context.rollback()
            throw error
        }
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
        if let id = detail.externalIds?.imdbId, !id.isEmpty { imdbID = id }
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
