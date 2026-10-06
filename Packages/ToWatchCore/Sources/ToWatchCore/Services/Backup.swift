import Foundation
import SwiftData

// Library backup: a self-contained JSON snapshot of everything, including TMDB metadata,
// so a restore works offline and doesn't refetch hundreds of titles.

public struct LibraryBackup: Codable, Sendable {
    public static let currentVersion = 1

    public var version = LibraryBackup.currentVersion
    public var exportedAt = Date.now
    public var movies: [MovieRecord] = []
    public var shows: [ShowRecord] = []
    public var spaces: [SpaceRecord] = []
    public var tags: [TagRecord] = []
    public var smartLists: [SmartListRecord] = []

    public struct NoteRecord: Codable, Sendable, Hashable {
        public var text: String
        public var createdAt: Date
        public var updatedAt: Date
    }

    public struct MovieRecord: Codable, Sendable {
        public var tmdbID: Int
        public var title: String
        public var originalTitle: String?
        public var overview: String?
        public var tagline: String?
        public var posterPath: String?
        public var backdropPath: String?
        public var releaseDate: Date?
        public var runtime: Int?
        public var genres: [String]
        public var releaseStatus: String?
        public var voteAverage: Double?
        public var imdbID: String?
        public var homepage: String?
        public var trailerKey: String?
        public var cast: [PersonCredit]
        public var directors: [PersonCredit]
        public var addedDate: Date
        public var isWatched: Bool
        public var watchedDate: Date?
        public var userRating: Double?
        public var isInBacklog: Bool
        public var isFavorite: Bool
        public var notes: [NoteRecord]
        public var spaceIDs: [UUID]
        public var tagIDs: [UUID]
    }

    public struct EpisodeRecord: Codable, Sendable {
        public var tmdbID: Int
        public var episodeNumber: Int
        public var name: String?
        public var overview: String?
        public var airDate: Date?
        public var runtime: Int?
        public var stillPath: String?
        public var isWatched: Bool
        public var watchedDate: Date?
        public var userRating: Double?
        public var notes: [NoteRecord]
    }

    public struct SeasonRecord: Codable, Sendable {
        public var tmdbID: Int
        public var seasonNumber: Int
        public var name: String?
        public var overview: String?
        public var posterPath: String?
        public var airDate: Date?
        public var episodes: [EpisodeRecord]
    }

    public struct ShowRecord: Codable, Sendable {
        public var tmdbID: Int
        public var name: String
        public var originalName: String?
        public var overview: String?
        public var tagline: String?
        public var posterPath: String?
        public var backdropPath: String?
        public var firstAirDate: Date?
        public var lastAirDate: Date?
        public var showStatus: String?
        public var genres: [String]
        public var networks: [String]
        public var numberOfSeasons: Int?
        public var numberOfEpisodes: Int?
        public var episodeRuntime: Int?
        public var voteAverage: Double?
        public var homepage: String?
        public var trailerKey: String?
        public var cast: [PersonCredit]
        public var creators: [PersonCredit]
        public var addedDate: Date
        public var userRating: Double?
        public var isInBacklog: Bool
        public var isFavorite: Bool
        public var isAbandoned: Bool
        public var notes: [NoteRecord]
        public var spaceIDs: [UUID]
        public var tagIDs: [UUID]
        public var seasons: [SeasonRecord]
    }

    public struct SpaceRecord: Codable, Sendable {
        public var uuid: UUID
        public var name: String
        public var symbolName: String
        public var colorName: String
        public var createdAt: Date
    }

    public struct TagRecord: Codable, Sendable {
        public var uuid: UUID
        public var name: String
        public var colorName: String
        public var createdAt: Date
    }

    public struct SmartListRecord: Codable, Sendable {
        public var uuid: UUID
        public var name: String
        public var symbolName: String
        public var colorName: String
        public var createdAt: Date
        public var rules: SmartListRules
    }

    public var titleCount: Int { movies.count + shows.count }
}

public enum BackupError: LocalizedError {
    case unreadable(String)
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case let .unreadable(detail): "This file isn't a ToWatchDB backup. \(detail)"
        case let .unsupportedVersion(version): "This backup (format \(version)) was made by a newer version of ToWatchDB."
        }
    }
}

public struct ImportSummary: Sendable, Equatable {
    public var moviesAdded = 0
    public var moviesMerged = 0
    public var showsAdded = 0
    public var showsMerged = 0
    public var collectionsAdded = 0

    public var description: String {
        var parts: [String] = []
        if moviesAdded + moviesMerged > 0 { parts.append("\(moviesAdded + moviesMerged) movies (\(moviesAdded) new)") }
        if showsAdded + showsMerged > 0 { parts.append("\(showsAdded + showsMerged) shows (\(showsAdded) new)") }
        if collectionsAdded > 0 { parts.append("\(collectionsAdded) new spaces, tags, or smart lists") }
        return parts.isEmpty ? "The backup was empty." : "Imported " + parts.formatted() + "."
    }
}

public enum BackupCoding {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func decode(_ data: Data) throws -> LibraryBackup {
        // Check the version first so a newer format gets a clear message rather than a decoding error.
        struct Header: Decodable { let version: Int }
        guard let header = try? decoder.decode(Header.self, from: data) else {
            throw BackupError.unreadable("It has no format version.")
        }
        guard header.version <= LibraryBackup.currentVersion else { throw BackupError.unsupportedVersion(header.version) }
        do {
            return try decoder.decode(LibraryBackup.self, from: data)
        } catch {
            throw BackupError.unreadable(error.localizedDescription)
        }
    }
}

// MARK: - Export

public extension LibraryService {
    func makeBackup() throws -> LibraryBackup {
        var backup = LibraryBackup()
        backup.movies = try context.fetch(FetchDescriptor<Movie>(sortBy: [SortDescriptor(\.addedDate)])).map(Self.record)
        backup.shows = try context.fetch(FetchDescriptor<TVShow>(sortBy: [SortDescriptor(\.addedDate)])).map(Self.record)
        backup.spaces = try context.fetch(FetchDescriptor<Space>()).map {
            .init(uuid: $0.uuid, name: $0.name, symbolName: $0.symbolName, colorName: $0.colorName, createdAt: $0.createdAt)
        }
        backup.tags = try context.fetch(FetchDescriptor<MediaTag>()).map {
            .init(uuid: $0.uuid, name: $0.name, colorName: $0.colorName, createdAt: $0.createdAt)
        }
        backup.smartLists = try context.fetch(FetchDescriptor<SmartList>()).map {
            .init(uuid: $0.uuid, name: $0.name, symbolName: $0.symbolName, colorName: $0.colorName, createdAt: $0.createdAt, rules: $0.rules)
        }
        return backup
    }

    func exportBackupData() throws -> Data {
        try BackupCoding.encoder.encode(makeBackup())
    }

    private static func notes(_ notes: [Note]?) -> [LibraryBackup.NoteRecord] {
        (notes ?? []).sorted { $0.createdAt < $1.createdAt }
            .map { .init(text: $0.text, createdAt: $0.createdAt, updatedAt: $0.updatedAt) }
    }

    private static func record(_ movie: Movie) -> LibraryBackup.MovieRecord {
        .init(tmdbID: movie.tmdbID, title: movie.title, originalTitle: movie.originalTitle, overview: movie.overview,
              tagline: movie.tagline, posterPath: movie.posterPath, backdropPath: movie.backdropPath,
              releaseDate: movie.releaseDate, runtime: movie.runtime, genres: movie.genres,
              releaseStatus: movie.releaseStatus, voteAverage: movie.voteAverage, imdbID: movie.imdbID,
              homepage: movie.homepage, trailerKey: movie.trailerKey, cast: movie.cast, directors: movie.directors,
              addedDate: movie.addedDate, isWatched: movie.isWatched, watchedDate: movie.watchedDate,
              userRating: movie.userRating, isInBacklog: movie.isInBacklog, isFavorite: movie.isFavorite,
              notes: notes(movie.notes), spaceIDs: (movie.spaces ?? []).map(\.uuid), tagIDs: (movie.tags ?? []).map(\.uuid))
    }

    private static func record(_ show: TVShow) -> LibraryBackup.ShowRecord {
        .init(tmdbID: show.tmdbID, name: show.name, originalName: show.originalName, overview: show.overview,
              tagline: show.tagline, posterPath: show.posterPath, backdropPath: show.backdropPath,
              firstAirDate: show.firstAirDate, lastAirDate: show.lastAirDate, showStatus: show.showStatus,
              genres: show.genres, networks: show.networks, numberOfSeasons: show.numberOfSeasons,
              numberOfEpisodes: show.numberOfEpisodes, episodeRuntime: show.episodeRuntime,
              voteAverage: show.voteAverage, homepage: show.homepage, trailerKey: show.trailerKey,
              cast: show.cast, creators: show.creators, addedDate: show.addedDate, userRating: show.userRating,
              isInBacklog: show.isInBacklog, isFavorite: show.isFavorite, isAbandoned: show.isAbandoned,
              notes: notes(show.notes), spaceIDs: (show.spaces ?? []).map(\.uuid), tagIDs: (show.tags ?? []).map(\.uuid),
              seasons: show.sortedSeasons.map { season in
                  .init(tmdbID: season.tmdbID, seasonNumber: season.seasonNumber, name: season.name,
                        overview: season.overview, posterPath: season.posterPath, airDate: season.airDate,
                        episodes: season.sortedEpisodes.map { episode in
                            .init(tmdbID: episode.tmdbID, episodeNumber: episode.episodeNumber, name: episode.name,
                                  overview: episode.overview, airDate: episode.airDate, runtime: episode.runtime,
                                  stillPath: episode.stillPath, isWatched: episode.isWatched,
                                  watchedDate: episode.watchedDate, userRating: episode.userRating,
                                  notes: notes(episode.notes))
                        })
              })
    }
}

// MARK: - Import (merge)

public extension LibraryService {
    /// Merges a backup into the library. Nothing already here is lost or duplicated:
    /// - Titles match by TMDB ID. New ones are created from the backup's metadata.
    /// - Watched, backlog, favorite, and abandoned are kept if set on either side; local dates and ratings win,
    ///   the backup fills in what's missing.
    /// - Notes are added unless the same text with the same creation date already exists.
    /// - Spaces, tags, and smart lists match by ID (tags also by name); memberships are unioned.
    @discardableResult
    func importBackup(_ backup: LibraryBackup) -> ImportSummary {
        var summary = ImportSummary()

        var spaces: [UUID: Space] = [:]
        for record in backup.spaces {
            if let existing = space(uuid: record.uuid) {
                spaces[record.uuid] = existing
            } else {
                let space = Space(name: record.name, symbolName: record.symbolName, colorName: record.colorName)
                space.uuid = record.uuid
                space.createdAt = record.createdAt
                context.insert(space)
                spaces[record.uuid] = space
                summary.collectionsAdded += 1
            }
        }
        var tags: [UUID: MediaTag] = [:]
        for record in backup.tags {
            if let existing = tag(uuid: record.uuid) ?? tag(named: record.name) {
                tags[record.uuid] = existing
            } else {
                let tag = MediaTag(name: record.name, colorName: record.colorName)
                tag.uuid = record.uuid
                tag.createdAt = record.createdAt
                context.insert(tag)
                tags[record.uuid] = tag
                summary.collectionsAdded += 1
            }
        }
        for record in backup.smartLists where smartList(uuid: record.uuid) == nil {
            // A backup tag can match an existing tag by name with a different ID; point the rules at the one kept.
            var rules = record.rules
            rules.tagIDs = Set(rules.tagIDs.map { tags[$0]?.uuid ?? $0 })
            rules.spaceIDs = Set(rules.spaceIDs.map { spaces[$0]?.uuid ?? $0 })
            let list = SmartList(name: record.name, rules: rules)
            list.uuid = record.uuid
            list.symbolName = record.symbolName
            list.colorName = record.colorName
            list.createdAt = record.createdAt
            context.insert(list)
            summary.collectionsAdded += 1
        }

        // One fetch each instead of one per record (which also had to search the growing unsaved inserts).
        var moviesByID = Dictionary(((try? context.fetch(FetchDescriptor<Movie>())) ?? []).map { ($0.tmdbID, $0) }) { first, _ in first }
        var showsByID = Dictionary(((try? context.fetch(FetchDescriptor<TVShow>())) ?? []).map { ($0.tmdbID, $0) }) { first, _ in first }

        for record in backup.movies {
            let existing = moviesByID[record.tmdbID]
            let movie = existing ?? makeMovie(record)
            moviesByID[record.tmdbID] = movie
            if existing == nil { summary.moviesAdded += 1 } else { summary.moviesMerged += 1 }

            if record.isWatched, !movie.isWatched {
                movie.isWatched = true
                movie.watchedDate = record.watchedDate
            } else if movie.isWatched, movie.watchedDate == nil {
                movie.watchedDate = record.watchedDate
            }
            movie.userRating = movie.userRating ?? record.userRating
            movie.isInBacklog = (movie.isInBacklog || record.isInBacklog) && !movie.isWatched
            movie.isFavorite = movie.isFavorite || record.isFavorite
            movie.addedDate = min(movie.addedDate, record.addedDate)
            mergeNotes(record.notes, into: movie.notes) { $0.movie = movie }
            movie.spaces = union(movie.spaces, record.spaceIDs.compactMap { spaces[$0] })
            movie.tags = union(movie.tags, record.tagIDs.compactMap { tags[$0] })
        }

        for record in backup.shows {
            let existing = showsByID[record.tmdbID]
            let show = existing ?? makeShow(record)
            showsByID[record.tmdbID] = show
            if existing == nil { summary.showsAdded += 1 } else { summary.showsMerged += 1 }

            show.userRating = show.userRating ?? record.userRating
            show.isInBacklog = show.isInBacklog || record.isInBacklog
            show.isFavorite = show.isFavorite || record.isFavorite
            show.isAbandoned = show.isAbandoned || record.isAbandoned
            show.addedDate = min(show.addedDate, record.addedDate)
            mergeNotes(record.notes, into: show.notes) { $0.show = show }
            show.spaces = union(show.spaces, record.spaceIDs.compactMap { spaces[$0] })
            show.tags = union(show.tags, record.tagIDs.compactMap { tags[$0] })
            mergeSeasons(record.seasons, into: show)
        }

        save()
        return summary
    }

    func importBackup(data: Data) throws -> ImportSummary {
        importBackup(try BackupCoding.decode(data))
    }

    private func makeMovie(_ record: LibraryBackup.MovieRecord) -> Movie {
        let movie = Movie(tmdbID: record.tmdbID, title: record.title)
        movie.originalTitle = record.originalTitle
        movie.overview = record.overview
        movie.tagline = record.tagline
        movie.posterPath = record.posterPath
        movie.backdropPath = record.backdropPath
        movie.releaseDate = record.releaseDate
        movie.runtime = record.runtime
        movie.genres = record.genres
        movie.releaseStatus = record.releaseStatus
        movie.voteAverage = record.voteAverage
        movie.imdbID = record.imdbID
        movie.homepage = record.homepage
        movie.trailerKey = record.trailerKey
        movie.castData = PersonCredit.encode(record.cast)
        movie.directorsData = PersonCredit.encode(record.directors)
        movie.addedDate = record.addedDate
        context.insert(movie)
        return movie
    }

    private func makeShow(_ record: LibraryBackup.ShowRecord) -> TVShow {
        let show = TVShow(tmdbID: record.tmdbID, name: record.name)
        show.originalName = record.originalName
        show.overview = record.overview
        show.tagline = record.tagline
        show.posterPath = record.posterPath
        show.backdropPath = record.backdropPath
        show.firstAirDate = record.firstAirDate
        show.lastAirDate = record.lastAirDate
        show.showStatus = record.showStatus
        show.genres = record.genres
        show.networks = record.networks
        show.numberOfSeasons = record.numberOfSeasons
        show.numberOfEpisodes = record.numberOfEpisodes
        show.episodeRuntime = record.episodeRuntime
        show.voteAverage = record.voteAverage
        show.homepage = record.homepage
        show.trailerKey = record.trailerKey
        show.castData = PersonCredit.encode(record.cast)
        show.creatorsData = PersonCredit.encode(record.creators)
        show.addedDate = record.addedDate
        context.insert(show)
        return show
    }

    private func mergeSeasons(_ records: [LibraryBackup.SeasonRecord], into show: TVShow) {
        var seasons = Dictionary((show.seasons ?? []).map { ($0.seasonNumber, $0) }) { first, _ in first }
        for record in records {
            let season = seasons[record.seasonNumber] ?? {
                let season = Season(tmdbID: record.tmdbID, seasonNumber: record.seasonNumber)
                season.name = record.name
                season.overview = record.overview
                season.posterPath = record.posterPath
                season.airDate = record.airDate
                context.insert(season)
                season.show = show
                seasons[record.seasonNumber] = season
                return season
            }()
            var episodes = Dictionary((season.episodes ?? []).map { ($0.episodeNumber, $0) }) { first, _ in first }
            for episodeRecord in record.episodes {
                let episode = episodes[episodeRecord.episodeNumber] ?? {
                    let episode = Episode(tmdbID: episodeRecord.tmdbID, seasonNumber: record.seasonNumber,
                                          episodeNumber: episodeRecord.episodeNumber)
                    episode.name = episodeRecord.name
                    episode.overview = episodeRecord.overview
                    episode.airDate = episodeRecord.airDate
                    episode.runtime = episodeRecord.runtime
                    episode.stillPath = episodeRecord.stillPath
                    context.insert(episode)
                    episode.season = season
                    episodes[episodeRecord.episodeNumber] = episode
                    return episode
                }()
                if episodeRecord.isWatched, !episode.isWatched {
                    episode.isWatched = true
                    episode.watchedDate = episodeRecord.watchedDate
                } else if episode.isWatched, episode.watchedDate == nil {
                    episode.watchedDate = episodeRecord.watchedDate
                }
                episode.userRating = episode.userRating ?? episodeRecord.userRating
                mergeNotes(episodeRecord.notes, into: episode.notes) { $0.episode = episode }
            }
        }
    }

    /// `existing` is an autoclosure: most records have no notes, and reading every episode's notes faults them in.
    private func mergeNotes(_ records: [LibraryBackup.NoteRecord], into existing: @autoclosure () -> [Note]?,
                            attach: (Note) -> Void) {
        guard !records.isEmpty else { return }
        let present = Set((existing() ?? []).map { NoteKey(text: $0.text, createdAt: $0.createdAt) })
        for record in records where !present.contains(NoteKey(text: record.text, createdAt: record.createdAt)) {
            let note = Note(text: record.text)
            note.createdAt = record.createdAt
            note.updatedAt = record.updatedAt
            context.insert(note)
            attach(note)
        }
    }

    private func union<M: PersistentModel>(_ current: [M]?, _ additions: [M]) -> [M] {
        var result = current ?? []
        for model in additions where !result.contains(where: { $0.persistentModelID == model.persistentModelID }) {
            result.append(model)
        }
        return result
    }
}

/// Notes are identified by text and creation time (to the second, since ISO 8601 drops fractions).
private struct NoteKey: Hashable {
    let text: String
    let createdAt: Int

    init(text: String, createdAt: Date) {
        self.text = text
        self.createdAt = Int(createdAt.timeIntervalSince1970.rounded(.down))
    }
}

// MARK: - CSV

public extension LibraryService {
    /// One row per title, for spreadsheets. Export only; restore uses the JSON backup.
    func exportCSV(now: Date = .now, timeZone: TimeZone = .current) throws -> String {
        let header = ["Type", "TMDB ID", "Title", "Year", "Status", "Watched Date", "Rating (0-10)", "Backlog", "Favorite",
                      "Episodes Watched", "Episodes Aired", "Genres", "Spaces", "Tags", "Added"]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        // Watch and added dates are the user's own moments, so they're written as local calendar days.
        let day = Date.ISO8601FormatStyle(timeZone: timeZone).year().month().day()
        func year(_ date: Date?) -> String { date.map { String(calendar.component(.year, from: $0)) } ?? "" }

        var rows = [header]
        for movie in try context.fetch(FetchDescriptor<Movie>(sortBy: [SortDescriptor(\.title)])) {
            rows.append(["Movie", String(movie.tmdbID), movie.title, year(movie.releaseDate), movie.watchStatus.label,
                         movie.watchedDate?.formatted(day) ?? "", movie.userRating.map { String(format: "%g", $0) } ?? "",
                         movie.isInBacklog ? "Yes" : "No", movie.isFavorite ? "Yes" : "No", "", "",
                         movie.genres.joined(separator: "; "),
                         (movie.spaces ?? []).map(\.name).sorted().joined(separator: "; "),
                         (movie.tags ?? []).map(\.name).sorted().joined(separator: "; "),
                         movie.addedDate.formatted(day)])
        }
        for show in try context.fetch(FetchDescriptor<TVShow>(sortBy: [SortDescriptor(\.name)])) {
            let progress = show.progressSummary(asOf: now)
            rows.append(["TV Show", String(show.tmdbID), show.name, year(show.firstAirDate), progress.status.label,
                         progress.lastWatched?.formatted(day) ?? "", show.userRating.map { String(format: "%g", $0) } ?? "",
                         show.isInBacklog ? "Yes" : "No", show.isFavorite ? "Yes" : "No",
                         String(show.watchedEpisodeCount()), String(progress.airedCount),
                         show.genres.joined(separator: "; "),
                         (show.spaces ?? []).map(\.name).sorted().joined(separator: "; "),
                         (show.tags ?? []).map(\.name).sorted().joined(separator: "; "),
                         show.addedDate.formatted(day)])
        }
        return rows.map { $0.map(Self.csvField).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    /// RFC 4180: quote fields containing commas, quotes, or line breaks; double embedded quotes.
    static func csvField(_ value: String) -> String {
        guard value.contains(where: { ",\"\r\n".contains($0) }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
