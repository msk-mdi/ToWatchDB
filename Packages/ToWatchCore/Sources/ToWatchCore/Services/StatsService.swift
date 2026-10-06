import Foundation

/// The time window stats cover. Watch dates are the user's own moments, so periods use the local calendar
/// (unlike TMDB release dates, which are UTC calendar days).
public enum StatsPeriod: Hashable, Sendable {
    case allTime
    case year(Int)
    case thisWeek
    case thisMonth
    case lastDays(Int)

    public var label: String {
        switch self {
        case .allTime: "All Time"
        case let .year(year): String(year)
        case .thisWeek: "This Week"
        case .thisMonth: "This Month"
        case let .lastDays(days): "Last \(days) Days"
        }
    }

    /// `nil` means unbounded (all time).
    public func interval(now: Date = .now, calendar: Calendar = .current) -> DateInterval? {
        switch self {
        case .allTime:
            return nil
        case let .year(year):
            guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
                  let end = calendar.date(byAdding: .year, value: 1, to: start) else { return nil }
            return DateInterval(start: start, end: end)
        case .thisWeek:
            return calendar.dateInterval(of: .weekOfYear, for: now)
        case .thisMonth:
            return calendar.dateInterval(of: .month, for: now)
        case let .lastDays(days):
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
            let start = calendar.date(byAdding: .day, value: -days, to: end)!
            return DateInterval(start: start, end: end)
        }
    }
}

public struct RankedEntry: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let count: Int
    public let imagePath: String?
}

public struct ActivityBucket: Hashable, Sendable, Identifiable {
    public enum Granularity: Sendable { case day, month, year }

    public let start: Date
    public var movies = 0
    public var episodes = 0
    public var minutes = 0

    public var id: Date { start }
}

public struct WatchStats: Hashable, Sendable {
    public var moviesWatched = 0
    public var episodesWatched = 0
    /// Distinct shows with at least one episode watched in the period.
    public var showsWatched = 0
    public var movieMinutes = 0
    public var episodeMinutes = 0
    public var topGenres: [RankedEntry] = []
    public var topActors: [RankedEntry] = []
    public var activity: [ActivityBucket] = []
    public var granularity: ActivityBucket.Granularity = .month
    public var mostWatchedShow: RankedEntry?
    public var longestMovie: RankedEntry?
    /// Posters of titles watched in the period, most recent first, for the Year in Review card.
    public var posterPaths: [String] = []
    /// Titles marked watched without a date. They count toward All Time only.
    public var undatedWatches = 0

    public var totalMinutes: Int { movieMinutes + episodeMinutes }
    public var isEmpty: Bool { moviesWatched == 0 && episodesWatched == 0 }
}

public enum StatsService {
    @MainActor
    public static func stats(movies: [Movie], shows: [TVShow], period: StatsPeriod,
                             now: Date = .now, calendar: Calendar = .current, topCount: Int = 10) -> WatchStats {
        let interval = period.interval(now: now, calendar: calendar)
        let inPeriod: (Date?) -> Bool = { date in
            guard let interval else { return true }
            return date.map { $0 >= interval.start && $0 < interval.end } ?? false
        }

        var stats = WatchStats()
        var events: [(date: Date, isMovie: Bool, minutes: Int)] = []
        var titleGenres: [[String]] = []
        var titleCast: [[PersonCredit]] = []
        var recentPosters: [(Date, String)] = []

        // Movies
        for movie in movies where movie.isWatched {
            if movie.watchedDate == nil { stats.undatedWatches += 1 }
            guard inPeriod(movie.watchedDate) else { continue }
            let minutes = movie.runtime ?? 0
            stats.moviesWatched += 1
            stats.movieMinutes += minutes
            if let date = movie.watchedDate { events.append((date, true, minutes)) }
            titleGenres.append(movie.genres)
            titleCast.append(movie.cast)
            if let poster = movie.posterPath { recentPosters.append((movie.watchedDate ?? .distantPast, poster)) }
            if minutes > (stats.longestMovie?.count ?? 0) {
                stats.longestMovie = RankedEntry(id: "movie-\(movie.tmdbID)", name: movie.title, count: minutes, imagePath: movie.posterPath)
            }
        }

        // Episodes, grouped by show
        for show in shows {
            // Order doesn't matter for counting, so skip sorting seasons and episodes.
            let episodes = (show.seasons ?? []).flatMap { $0.episodes ?? [] }.filter(\.isWatched)
            stats.undatedWatches += episodes.count { $0.watchedDate == nil }
            let watched = episodes.filter { inPeriod($0.watchedDate) }
            guard !watched.isEmpty else { continue }
            stats.showsWatched += 1
            stats.episodesWatched += watched.count
            for episode in watched {
                let minutes = episode.runtime ?? show.episodeRuntime ?? 0
                stats.episodeMinutes += minutes
                if let date = episode.watchedDate { events.append((date, false, minutes)) }
            }
            titleGenres.append(show.genres)
            titleCast.append(show.cast)
            if let poster = show.posterPath {
                recentPosters.append((watched.compactMap(\.watchedDate).max() ?? .distantPast, poster))
            }
            if watched.count > (stats.mostWatchedShow?.count ?? 0) {
                stats.mostWatchedShow = RankedEntry(id: "tv-\(show.tmdbID)", name: show.name, count: watched.count, imagePath: show.posterPath)
            }
        }

        stats.topGenres = rank(titleGenres.flatMap { Array(Set($0)) }.map { ($0, $0, nil as String?) }, limit: topCount)
        stats.topActors = rank(titleCast.flatMap { cast in
            // A person counts once per title even if credited twice.
            Dictionary(cast.map { ($0.id, $0) }) { first, _ in first }.values.map { ("person-\($0.id)", $0.name, $0.profilePath) }
        }, limit: topCount)
        stats.posterPaths = recentPosters.sorted { $0.0 > $1.0 }.map(\.1)

        let bucketRange = interval ?? events.map(\.date).min().map { DateInterval(start: $0, end: now) }
        if let bucketRange {
            stats.granularity = granularity(for: bucketRange)
            stats.activity = buckets(events, over: bucketRange, granularity: stats.granularity, calendar: calendar)
        }
        return stats
    }

    /// Years that have at least one dated watch, newest first.
    @MainActor
    public static func watchYears(movies: [Movie], shows: [TVShow], calendar: Calendar = .current) -> [Int] {
        let dates = movies.compactMap(\.watchedDate)
            + shows.flatMap { ($0.seasons ?? []).flatMap { $0.episodes ?? [] } }.compactMap(\.watchedDate)
        return Set(dates.map { calendar.component(.year, from: $0) }).sorted(by: >)
    }

    // MARK: Helpers

    /// Counts occurrences by id, highest first, ties broken by name.
    static func rank(_ entries: [(id: String, name: String, image: String?)], limit: Int) -> [RankedEntry] {
        var counts: [String: (name: String, image: String?, count: Int)] = [:]
        for entry in entries {
            counts[entry.id, default: (entry.name, entry.image, 0)].count += 1
        }
        return counts
            .map { RankedEntry(id: $0.key, name: $0.value.name, count: $0.value.count, imagePath: $0.value.image) }
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
            .prefix(limit)
            .map { $0 }
    }

    static func granularity(for range: DateInterval) -> ActivityBucket.Granularity {
        let days = range.duration / 86_400
        if days <= 45 { return .day }
        if days <= 3 * 366 { return .month }
        return .year
    }

    static func buckets(_ events: [(date: Date, isMovie: Bool, minutes: Int)], over range: DateInterval,
                        granularity: ActivityBucket.Granularity, calendar: Calendar) -> [ActivityBucket] {
        let component: Calendar.Component = switch granularity {
        case .day: .day
        case .month: .month
        case .year: .year
        }
        func bucketStart(_ date: Date) -> Date { calendar.dateInterval(of: component, for: date)?.start ?? date }

        var buckets: [Date: ActivityBucket] = [:]
        var cursor = bucketStart(range.start)
        while cursor < range.end {
            buckets[cursor] = ActivityBucket(start: cursor)
            guard let next = calendar.date(byAdding: component, value: 1, to: cursor) else { break }
            cursor = next
        }
        for event in events {
            let key = bucketStart(event.date)
            var bucket = buckets[key] ?? ActivityBucket(start: key)
            if event.isMovie { bucket.movies += 1 } else { bucket.episodes += 1 }
            bucket.minutes += event.minutes
            buckets[key] = bucket
        }
        return buckets.values.sorted { $0.start < $1.start }
    }
}
