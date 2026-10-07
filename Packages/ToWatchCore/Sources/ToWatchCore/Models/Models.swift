import Foundation
import SwiftData

// SwiftData models. Kept CloudKit-compatible so sync can be switched on later:
// every stored property is optional or defaulted, nothing is `.unique`, and relationships are optional with inverses.

/// A person in a title's credits, stored as JSON on the owning model.
public struct PersonCredit: Codable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let name: String
    public let role: String?
    public let profilePath: String?

    public init(id: Int, name: String, role: String?, profilePath: String?) {
        self.id = id
        self.name = name
        self.role = role
        self.profilePath = profilePath
    }
}

public enum WatchStatus: String, Codable, Sendable, CaseIterable, Identifiable {
    case notWatched, watching, watched, abandoned

    public var id: Self { self }

    public var label: String {
        switch self {
        case .notWatched: "Not Watched"
        case .watching: "Watching"
        case .watched: "Watched"
        case .abandoned: "Abandoned"
        }
    }
}

@Model
public final class Movie {
    public var tmdbID: Int = 0
    public var title: String = ""
    public var originalTitle: String?
    public var overview: String?
    public var tagline: String?
    public var posterPath: String?
    public var backdropPath: String?
    public var releaseDate: Date?
    public var runtime: Int?
    public var genres: [String] = []
    public var releaseStatus: String?
    public var voteAverage: Double?
    public var imdbID: String?
    /// IMDb's 1–10 user rating, cached from `IMDbClient` and refreshed every few days.
    public var imdbRating: Double?
    public var imdbVoteCount: Int?
    public var imdbRatingDate: Date?
    public var homepage: String?
    public var trailerKey: String?
    public var castData: Data?
    public var directorsData: Data?

    public var addedDate: Date = Date.now
    public var lastRefreshed: Date?
    public var isWatched: Bool = false
    public var watchedDate: Date?
    public var userRating: Double?
    public var isInBacklog: Bool = false
    public var isFavorite: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \Note.movie)
    public var notes: [Note]? = []

    // Inverses are declared on Space and MediaTag.
    public var spaces: [Space]? = []
    public var tags: [MediaTag]? = []

    public init(tmdbID: Int, title: String) {
        self.tmdbID = tmdbID
        self.title = title
    }

    public var cast: [PersonCredit] { PersonCredit.decode(castData) }
    public var directors: [PersonCredit] { PersonCredit.decode(directorsData) }

    public var watchStatus: WatchStatus { isWatched ? .watched : .notWatched }

    public func isReleased(asOf now: Date = .now) -> Bool {
        guard let releaseDate else { return false }
        return releaseDate <= TMDBDate.today(now)
    }
}

@Model
public final class TVShow {
    public var tmdbID: Int = 0
    public var name: String = ""
    public var originalName: String?
    public var overview: String?
    public var tagline: String?
    public var posterPath: String?
    public var backdropPath: String?
    public var firstAirDate: Date?
    public var lastAirDate: Date?
    public var showStatus: String?
    public var genres: [String] = []
    public var networks: [String] = []
    public var numberOfSeasons: Int?
    public var numberOfEpisodes: Int?
    public var episodeRuntime: Int?
    public var voteAverage: Double?
    public var imdbID: String?
    /// IMDb's 1–10 user rating, cached from `IMDbClient` and refreshed every few days.
    public var imdbRating: Double?
    public var imdbVoteCount: Int?
    public var imdbRatingDate: Date?
    public var homepage: String?
    public var trailerKey: String?
    public var castData: Data?
    public var creatorsData: Data?

    public var addedDate: Date = Date.now
    public var lastRefreshed: Date?
    public var userRating: Double?
    public var isInBacklog: Bool = false
    public var isFavorite: Bool = false
    public var isAbandoned: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \Season.show)
    public var seasons: [Season]? = []

    @Relationship(deleteRule: .cascade, inverse: \Note.show)
    public var notes: [Note]? = []

    public var spaces: [Space]? = []
    public var tags: [MediaTag]? = []

    public init(tmdbID: Int, name: String) {
        self.tmdbID = tmdbID
        self.name = name
    }

    public var cast: [PersonCredit] { PersonCredit.decode(castData) }
    public var creators: [PersonCredit] { PersonCredit.decode(creatorsData) }

    public var sortedSeasons: [Season] {
        (seasons ?? []).sorted { $0.seasonNumber < $1.seasonNumber }
    }

    /// Episodes of regular seasons (specials, season 0, don't count toward progress), in airing order.
    public var regularEpisodes: [Episode] {
        sortedSeasons.filter { $0.seasonNumber > 0 }.flatMap(\.sortedEpisodes)
    }

    /// Whether TMDB may still add episodes to this show.
    public var isOngoing: Bool {
        guard let showStatus else { return true }
        return ["Returning Series", "In Production", "Planned", "Pilot"].contains(showStatus)
    }
}

@Model
public final class Season {
    public var tmdbID: Int = 0
    public var seasonNumber: Int = 0
    public var name: String?
    public var overview: String?
    public var posterPath: String?
    public var airDate: Date?

    public var show: TVShow?

    @Relationship(deleteRule: .cascade, inverse: \Episode.season)
    public var episodes: [Episode]? = []

    public init(tmdbID: Int, seasonNumber: Int) {
        self.tmdbID = tmdbID
        self.seasonNumber = seasonNumber
    }

    public var sortedEpisodes: [Episode] {
        (episodes ?? []).sorted { $0.episodeNumber < $1.episodeNumber }
    }

    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return seasonNumber == 0 ? "Specials" : "Season \(seasonNumber)"
    }
}

@Model
public final class Episode {
    public var tmdbID: Int = 0
    public var seasonNumber: Int = 0
    public var episodeNumber: Int = 0
    public var name: String?
    public var overview: String?
    public var airDate: Date?
    public var runtime: Int?
    public var stillPath: String?

    public var isWatched: Bool = false
    public var watchedDate: Date?
    public var userRating: Double?

    public var season: Season?

    @Relationship(deleteRule: .cascade, inverse: \Note.episode)
    public var notes: [Note]? = []

    public init(tmdbID: Int, seasonNumber: Int, episodeNumber: Int) {
        self.tmdbID = tmdbID
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
    }

    public var show: TVShow? { season?.show }

    /// "S01E05"
    public var code: String {
        String(format: "S%02dE%02d", seasonNumber, episodeNumber)
    }

    public func hasAired(asOf now: Date = .now) -> Bool {
        guard let airDate else { return false }
        return airDate <= TMDBDate.today(now)
    }
}

@Model
public final class Note {
    public var text: String = ""
    public var createdAt: Date = Date.now
    public var updatedAt: Date = Date.now

    public var movie: Movie?
    public var show: TVShow?
    public var episode: Episode?

    public init(text: String) {
        self.text = text
    }
}

public enum ToWatchSchema {
    public static let models: [any PersistentModel.Type] = [
        Movie.self, TVShow.self, Season.self, Episode.self, Note.self,
        Space.self, MediaTag.self, SmartList.self,
    ]
}

extension PersonCredit {
    static func decode(_ data: Data?) -> [PersonCredit] {
        guard let data else { return [] }
        return (try? decoder.decode([PersonCredit].self, from: data)) ?? []
    }

    static func encode(_ people: [PersonCredit]) -> Data? {
        people.isEmpty ? nil : try? encoder.encode(people)
    }

    private static let decoder = JSONDecoder()
    private static let encoder = JSONEncoder()
}

extension PersistentModel {
    /// False once the model has been deleted, whether or not the deletion is saved yet. Code that holds a model
    /// across an `await` checks this before writing: the user or a sync may have deleted it meanwhile, and
    /// SwiftData can trap on a write to a deleted model.
    public var isLive: Bool { modelContext != nil && !isDeleted }
}
