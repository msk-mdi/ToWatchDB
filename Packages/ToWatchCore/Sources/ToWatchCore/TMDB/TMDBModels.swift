import Foundation

// Codable mirrors of the TMDB v3 JSON payloads we use. Decoded with `.convertFromSnakeCase`.

public struct TMDBPage<Item: Decodable & Sendable>: Decodable, Sendable {
    public let page: Int
    public let results: [Item]
    public let totalPages: Int?
    public let totalResults: Int?
}

public struct TMDBGenre: Codable, Sendable, Hashable {
    public let id: Int
    public let name: String
}

public struct TMDBMovieSummary: Codable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let title: String
    public let originalTitle: String?
    public let overview: String?
    public let posterPath: String?
    public let backdropPath: String?
    public let releaseDate: String?
    public let voteAverage: Double?
}

public struct TMDBTVSummary: Codable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let name: String
    public let originalName: String?
    public let overview: String?
    public let posterPath: String?
    public let backdropPath: String?
    public let firstAirDate: String?
    public let voteAverage: Double?
}

public struct TMDBCastMember: Codable, Sendable, Hashable {
    public let id: Int
    public let name: String
    public let character: String?
    public let profilePath: String?
    public let order: Int?
}

public struct TMDBCrewMember: Codable, Sendable, Hashable {
    public let id: Int
    public let name: String
    public let job: String?
    public let department: String?
    public let profilePath: String?
}

public struct TMDBCredits: Codable, Sendable, Hashable {
    public let cast: [TMDBCastMember]
    public let crew: [TMDBCrewMember]
}

public struct TMDBVideo: Codable, Sendable, Hashable {
    public let key: String
    public let site: String
    public let type: String
    public let name: String?
    public let official: Bool?
}

public struct TMDBVideoList: Codable, Sendable, Hashable {
    public let results: [TMDBVideo]

    /// Best YouTube trailer key: official trailers first, then any trailer, then teasers.
    /// Results come in the user's language first (see `TMDBClient.videoLanguages`), then English.
    public var bestTrailerKey: String? {
        let youtube = results.filter { $0.site == "YouTube" }
        let trailers = youtube.filter { $0.type == "Trailer" }
        return (trailers.first { $0.official == true } ?? trailers.first ?? youtube.first { $0.type == "Teaser" })?.key
    }
}

public struct TMDBMovieDetail: Codable, Sendable, Hashable {
    public let id: Int
    public let title: String
    public let originalTitle: String?
    public let overview: String?
    public let tagline: String?
    public let posterPath: String?
    public let backdropPath: String?
    public let releaseDate: String?
    public let runtime: Int?
    public let genres: [TMDBGenre]?
    public let status: String?
    public let voteAverage: Double?
    public let imdbId: String?
    public let homepage: String?
    public let credits: TMDBCredits?
    public let videos: TMDBVideoList?
}

public struct TMDBCreator: Codable, Sendable, Hashable {
    public let id: Int
    public let name: String
    public let profilePath: String?
}

public struct TMDBNetwork: Codable, Sendable, Hashable {
    public let id: Int
    public let name: String
}

public struct TMDBSeasonSummary: Codable, Sendable, Hashable {
    public let id: Int
    public let seasonNumber: Int
    public let name: String?
    public let overview: String?
    public let posterPath: String?
    public let airDate: String?
    public let episodeCount: Int?
}

public struct TMDBTVDetail: Codable, Sendable, Hashable {
    public let id: Int
    public let name: String
    public let originalName: String?
    public let overview: String?
    public let tagline: String?
    public let posterPath: String?
    public let backdropPath: String?
    public let firstAirDate: String?
    public let lastAirDate: String?
    public let status: String?
    public let genres: [TMDBGenre]?
    public let numberOfSeasons: Int?
    public let numberOfEpisodes: Int?
    public let episodeRunTime: [Int]?
    public let voteAverage: Double?
    public let homepage: String?
    public let seasons: [TMDBSeasonSummary]?
    public let createdBy: [TMDBCreator]?
    public let networks: [TMDBNetwork]?
    public let credits: TMDBCredits?
    public let videos: TMDBVideoList?
}

public struct TMDBEpisode: Codable, Sendable, Hashable {
    public let id: Int
    public let episodeNumber: Int
    public let seasonNumber: Int
    public let name: String?
    public let overview: String?
    public let airDate: String?
    public let runtime: Int?
    public let stillPath: String?
    public let voteAverage: Double?
}

public struct TMDBSeasonDetail: Codable, Sendable, Hashable {
    public let id: Int
    public let seasonNumber: Int
    public let name: String?
    public let overview: String?
    public let posterPath: String?
    public let airDate: String?
    public let episodes: [TMDBEpisode]
}

public struct TMDBErrorBody: Decodable, Sendable {
    public let statusMessage: String?
}

/// TMDB dates are `yyyy-MM-dd` strings (sometimes empty). They're calendar days, so they're parsed in UTC
/// and compared against the start of "today" in UTC too, which keeps "released today" stable across time zones.
public enum TMDBDate {
    public static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        return try? Date(string, strategy: Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day())
    }

    /// The year of a TMDB `yyyy-MM-dd` date.
    public static func year(_ string: String?) -> Int? {
        string.flatMap { Int($0.prefix(4)) }
    }
}
