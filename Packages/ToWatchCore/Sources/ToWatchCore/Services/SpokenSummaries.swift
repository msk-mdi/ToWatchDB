import Foundation

/// Sentences for Siri and Shortcuts results. Kept here, apart from the intents, so they're testable.
public enum SpokenSummaries {
    public static func nextEpisodes(_ shows: [TVShow], limit: Int = 5, now: Date = .now) -> String {
        let queue = shows
            .filter { !$0.isAbandoned }
            .compactMap { show in show.nextEpisodeToWatch(asOf: now).map { (show, $0) } }
            .sorted { ($0.0.lastWatchedDate ?? .distantPast) > ($1.0.lastWatchedDate ?? .distantPast) }
        guard !queue.isEmpty else { return "You're all caught up. No episodes left to watch." }
        let items = queue.prefix(limit).map { show, episode in "\(show.name) \(episode.code)" }
        let more = queue.count > limit ? ", and \(queue.count - limit) more" : ""
        return "You have \(queue.count) show\(queue.count == 1 ? "" : "s") to continue: \(items.formatted())\(more)."
    }

    public static func upcoming(_ items: [UpcomingItem], limit: Int = 5, now: Date = .now) -> String {
        guard !items.isEmpty else { return "Nothing from your library is coming up." }
        let described = items.prefix(limit).map { item -> String in
            let when = item.date.map { relativeDay($0, now: now) } ?? ""
            switch item {
            case let .movie(movie): return "\(movie.title) \(when)"
            case let .episode(episode): return "\(episode.show?.name ?? "An episode") \(episode.code) \(when)"
            }
        }
        let more = items.count > limit ? ", and \(items.count - limit) more" : ""
        return "Coming up: \(described.formatted())\(more)."
    }

    public static func markedWatched(_ episode: Episode, next: Episode?) -> String {
        let marked = "Marked \(episode.show?.name ?? "the episode") \(episode.code) as watched."
        guard let next else { return marked + " You're all caught up." }
        return marked + " Next up: \(next.code)" + (next.name.map { ", \($0)." } ?? ".")
    }

    public static func stats(_ stats: WatchStats, periodLabel: String) -> String {
        guard !stats.isEmpty else { return "You haven't watched anything \(periodPhrase(periodLabel))." }
        var parts: [String] = []
        if stats.moviesWatched > 0 { parts.append("\(stats.moviesWatched) movie\(stats.moviesWatched == 1 ? "" : "s")") }
        if stats.episodesWatched > 0 { parts.append("\(stats.episodesWatched) episode\(stats.episodesWatched == 1 ? "" : "s")") }
        let time = Duration.seconds(stats.totalMinutes * 60)
            .formatted(.units(allowed: [.days, .hours, .minutes], width: .wide, maximumUnitCount: 2))
        let phrase = periodPhrase(periodLabel)
        return phrase.prefix(1).uppercased() + phrase.dropFirst() + " you watched \(parts.formatted()), \(time) in total."
    }

    public static func whereToWatch(_ title: String, offers: TMDBCountryProviders?, countryName: String) -> String {
        guard let offers, !offers.sections.isEmpty else {
            return "\(title) isn't available to stream, rent, or buy in \(countryName)."
        }
        let described = offers.sections.map { section in
            "\(section.kind.label.lowercased()) on \(section.providers.prefix(4).map(\.providerName).formatted())"
        }
        return "In \(countryName), you can \(described.formatted(.list(type: .or)))."
    }

    /// "2026" → "in 2026", "All Time" → "so far", "Last 30 Days" → "in the last 30 days", "This Week" → "this week".
    private static func periodPhrase(_ label: String) -> String {
        if label.first?.isNumber == true { return "in \(label)" }
        if label == "All Time" { return "so far" }
        if label.hasPrefix("Last ") { return "in the " + label.lowercased() }
        return label.lowercased()
    }

    private static func relativeDay(_ date: Date, now: Date) -> String {
        switch UpcomingService.daysUntil(date, now: now) {
        case 0: "today"
        case 1: "tomorrow"
        case let days where days < 7: "in \(days) days"
        default: "on \(date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt)))"
        }
    }
}
