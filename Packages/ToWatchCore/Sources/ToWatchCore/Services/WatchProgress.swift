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
        if isAbandoned { return .abandoned }
        let aired = airedEpisodes(asOf: now)
        let watched = aired.count { $0.isWatched }
        if watched == 0 { return regularEpisodes.contains(where: \.isWatched) ? .watching : .notWatched }
        return watched == aired.count ? .watched : .watching
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

public extension Season {
    func airedEpisodes(asOf now: Date = .now) -> [Episode] {
        sortedEpisodes.filter { $0.hasAired(asOf: now) }
    }

    var isFullyWatched: Bool {
        let aired = airedEpisodes()
        return !aired.isEmpty && aired.allSatisfy(\.isWatched)
    }
}
