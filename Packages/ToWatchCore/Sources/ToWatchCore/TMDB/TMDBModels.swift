import Foundation
import Synchronization

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
    public let externalIds: TMDBExternalIDs?
}

/// A show's IDs on other sites (movies carry `imdb_id` directly).
public struct TMDBExternalIDs: Codable, Sendable, Hashable {
    public let imdbId: String?
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

/// TMDB dates are `yyyy-MM-dd` strings (sometimes empty). They're calendar days, so they're parsed as UTC
/// midnights and compared against `today`: the user's local date, written the same way.
public enum TMDBDate {
    public static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        return try? Date(string, strategy: Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day())
    }

    /// The user's current calendar day as a TMDB date (its UTC midnight). Comparing against the UTC day instead
    /// made tomorrow's episodes count as aired on a US evening, and kept yesterday's as "today" in Asia.
    public static func today(_ now: Date = .now, timeZone: TimeZone = .current) -> Date {
        // Called for every episode in a progress pass; building a calendar each time was most of its cost.
        if let last = lastToday.withLock({ $0 }), last.timeZone == timeZone, last.interval.start <= now, now < last.interval.end {
            return last.day
        }
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        let components = local.dateComponents([.year, .month, .day], from: now)
        let day = utcCalendar.date(from: components) ?? utcCalendar.startOfDay(for: now)
        if let interval = local.dateInterval(of: .day, for: now) {
            lastToday.withLock { $0 = Today(timeZone: timeZone, interval: interval, day: day) }
        }
        return day
    }

    private struct Today: Sendable {
        let timeZone: TimeZone
        /// The local day `day` stands for.
        let interval: DateInterval
        let day: Date
    }

    private static let lastToday = Mutex<Today?>(nil)

    /// The UTC day a TMDB date falls on.
    public static func day(of date: Date) -> Date {
        utcCalendar.startOfDay(for: date)
    }

    static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    /// The year of a TMDB `yyyy-MM-dd` date.
    public static func year(_ string: String?) -> Int? {
        string.flatMap { Int($0.prefix(4)) }
    }
}
