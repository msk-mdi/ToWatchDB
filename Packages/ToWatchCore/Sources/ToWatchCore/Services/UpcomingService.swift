import Foundation

public enum UpcomingItem: Identifiable {
    case movie(Movie)
    case episode(Episode)

    public var id: String {
        switch self {
        case let .movie(movie): "movie-\(movie.tmdbID)"
        case let .episode(episode): "episode-\(episode.tmdbID)-\(episode.code)"
        }
    }

    public var date: Date? {
        switch self {
        case let .movie(movie): movie.releaseDate
        case let .episode(episode): episode.airDate
        }
    }
}

public enum UpcomingService {
    /// Start of the current UTC day. TMDB dates are UTC midnights, so an item dated today counts as upcoming.
    public static func startOfToday(_ now: Date = .now) -> Date {
        utcCalendar.startOfDay(for: now)
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    /// Movies releasing today or later, soonest first.
    public static func upcomingMovies(_ movies: [Movie], now: Date = .now) -> [Movie] {
        let today = startOfToday(now)
        return movies
            .filter { movie in movie.releaseDate.map { $0 >= today } ?? false }
            .sorted { $0.releaseDate! < $1.releaseDate! }
    }

    /// Unwatched episodes airing today or later, soonest first. Abandoned shows are excluded.
    public static func upcomingEpisodes(_ shows: [TVShow], now: Date = .now) -> [Episode] {
        let today = startOfToday(now)
        var episodes: [Episode] = []
        for show in shows where !show.isAbandoned {
            show.forEachRegularEpisode { episode in
                if !episode.isWatched, let airDate = episode.airDate, airDate >= today { episodes.append(episode) }
            }
        }
        return episodes
            .sorted { ($0.airDate!, $0.seasonNumber, $0.episodeNumber) < ($1.airDate!, $1.seasonNumber, $1.episodeNumber) }
    }

    /// Movies and episodes merged by date.
    public static func upcoming(movies: [Movie], shows: [TVShow], now: Date = .now) -> [UpcomingItem] {
        let items = upcomingMovies(movies, now: now).map(UpcomingItem.movie)
            + upcomingEpisodes(shows, now: now).map(UpcomingItem.episode)
        return items.sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
    }

    /// Whole days from today until `date` (0 = today).
    public static func daysUntil(_ date: Date, now: Date = .now) -> Int {
        utcCalendar.dateComponents([.day], from: startOfToday(now), to: utcCalendar.startOfDay(for: date)).day ?? 0
    }
}
