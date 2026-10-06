import Foundation

public extension TVShow {
    /// Regular episodes that have aired as of `now`.
    func airedEpisodes(asOf now: Date = .now) -> [Episode] {
        regularEpisodes.filter { $0.hasAired(asOf: now) }
    }

    func watchedEpisodeCount() -> Int {
        regularEpisodes.count { $0.isWatched }
    }

    /// Fraction of aired regular episodes that are watched (0...1).
    func progress(asOf now: Date = .now) -> Double {
        let aired = airedEpisodes(asOf: now)
        guard !aired.isEmpty else { return 0 }
        return Double(aired.count { $0.isWatched }) / Double(aired.count)
    }

    /// - Abandoned wins over everything.
    /// - Watched: every aired regular episode is watched (a returning show you're caught up on counts as watched).
    /// - Watching: at least one episode watched but some aired ones aren't.
    func watchStatus(asOf now: Date = .now) -> WatchStatus {
        progressSummary(asOf: now).status
    }

    /// Status, progress, and next episode from a single pass over the episodes. Building the sorted episode
    /// list touches every season and episode, so screens that need several of these should call this once.
    func progressSummary(asOf now: Date = .now) -> ShowProgress {
        var aired = 0, watchedAired = 0, watchedAny = 0
        var next: Episode?
        for episode in regularEpisodes {
            if episode.isWatched { watchedAny += 1 }
            guard episode.hasAired(asOf: now) else { continue }
            aired += 1
            if episode.isWatched { watchedAired += 1 } else if next == nil { next = episode }
        }
        let status: WatchStatus = if isAbandoned {
            .abandoned
        } else if watchedAired == 0 {
            watchedAny > 0 ? .watching : .notWatched
        } else {
            watchedAired == aired ? .watched : .watching
        }
        return ShowProgress(status: status, fraction: aired == 0 ? 0 : Double(watchedAired) / Double(aired),
                            nextEpisode: next, airedCount: aired, watchedAiredCount: watchedAired)
    }

    /// The first aired, unwatched regular episode, in airing order.
    func nextEpisodeToWatch(asOf now: Date = .now) -> Episode? {
        regularEpisodes.first { !$0.isWatched && $0.hasAired(asOf: now) }
    }

    /// The next episode that hasn't aired yet.
    func nextEpisodeToAir(asOf now: Date = .now) -> Episode? {
        regularEpisodes.first { ep in ep.airDate.map { $0 > now } ?? false }
    }

    /// Most recent date any episode was marked watched, used to order "Next to Watch".
    var lastWatchedDate: Date? {
        regularEpisodes.compactMap(\.watchedDate).max()
    }
}

/// See `TVShow.progressSummary(asOf:)`.
public struct ShowProgress {
    public let status: WatchStatus
    /// Fraction of aired regular episodes watched (0...1).
    public let fraction: Double
    /// The first aired, unwatched regular episode.
    public let nextEpisode: Episode?
    public let airedCount: Int
    public let watchedAiredCount: Int
}

public extension Season {
    func airedEpisodes(asOf now: Date = .now) -> [Episode] {
        sortedEpisodes.filter { $0.hasAired(asOf: now) }
    }

    var isFullyWatched: Bool {
        let aired = airedEpisodes()
        return !aired.isEmpty && aired.allSatisfy(\.isWatched)
    }
}
