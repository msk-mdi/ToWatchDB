import Foundation
import SwiftData

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
    /// The user's current day as a TMDB date (a UTC midnight), so an item dated today counts as upcoming.
    public static func startOfToday(_ now: Date = .now) -> Date {
        TMDBDate.today(now)
    }

    private static var utcCalendar: Calendar { TMDBDate.utcCalendar }

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

    /// Same as `upcoming(movies:shows:now:)`, but the store does the filtering: only the few future titles and
    /// unwatched episodes are loaded, instead of every movie and every episode in the library.
    @MainActor
    public static func upcoming(in context: ModelContext, now: Date = .now) -> [UpcomingItem] {
        let today = startOfToday(now)
        let movies = FetchDescriptor<Movie>(
            predicate: #Predicate { $0.releaseDate != nil && $0.releaseDate! >= today },
            sortBy: [SortDescriptor(\.releaseDate)]
        )
        let episodes = FetchDescriptor<Episode>(
            predicate: #Predicate { !$0.isWatched && $0.seasonNumber > 0 && $0.airDate != nil && $0.airDate! >= today },
            sortBy: [SortDescriptor(\.airDate), SortDescriptor(\.seasonNumber), SortDescriptor(\.episodeNumber)]
        )
        let items = ((try? context.fetch(movies)) ?? []).map(UpcomingItem.movie)
            + ((try? context.fetch(episodes)) ?? []).filter { $0.show?.isAbandoned == false }.map(UpcomingItem.episode)
        return items.sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
    }

    /// Whole days from today until `date` (0 = today).
    public static func daysUntil(_ date: Date, now: Date = .now) -> Int {
        utcCalendar.dateComponents([.day], from: startOfToday(now), to: utcCalendar.startOfDay(for: date)).day ?? 0
    }
}
