import Foundation
import SwiftData

public extension TVShow {
    /// Regular episodes that have aired as of `now`.
    func airedEpisodes(asOf now: Date = .now) -> [Episode] {
        regularEpisodes.filter { $0.hasAired(asOf: now) }
    }

    func watchedEpisodeCount() -> Int {
        var count = 0
        forEachRegularEpisode { if $0.isWatched { count += 1 } }
        return count
    }

    /// Fraction of aired regular episodes that are watched (0...1).
    func progress(asOf now: Date = .now) -> Double {
        progressSummary(asOf: now).fraction
    }

    /// - Abandoned wins over everything.
    /// - Watched: every aired regular episode is watched (a returning show you're caught up on counts as watched).
    /// - Watching: at least one episode watched but some aired ones aren't.
    func watchStatus(asOf now: Date = .now) -> WatchStatus {
        progressSummary(asOf: now).status
    }

    /// Status, progress, next episode, and last watch date from a single pass over the episodes, without
    /// sorting them. It still touches every season and episode, so screens that need several of these
    /// should call this once.
    func progressSummary(asOf now: Date = .now) -> ShowProgress {
        progressSummary(asOf: now, forEachEpisode: forEachRegularEpisode)
    }

    /// Every show's progress, keyed by show. Reads the episodes in one fetch and groups them through their
    /// season: the first read of each `show.seasons` and `season.episodes` materializes the relationship,
    /// which took about 3 s for 300 shows of 72 episodes (prefetching didn't help), against about 0.6 s here.
    static func progressSummaries(in context: ModelContext, asOf now: Date = .now) throws -> [PersistentIdentifier: ShowProgress] {
        var showBySeason: [PersistentIdentifier: PersistentIdentifier] = [:]
        for season in try context.fetch(FetchDescriptor<Season>(predicate: #Predicate { $0.seasonNumber > 0 })) {
            if let show = season.show { showBySeason[season.persistentModelID] = show.persistentModelID }
        }
        var episodesByShow: [PersistentIdentifier: [Episode]] = [:]
        for episode in try context.fetch(FetchDescriptor<Episode>()) {
            guard let season = episode.season, let show = showBySeason[season.persistentModelID] else { continue }
            episodesByShow[show, default: []].append(episode)
        }
        var progress: [PersistentIdentifier: ShowProgress] = [:]
        for show in try context.fetch(FetchDescriptor<TVShow>()) {
            let episodes = episodesByShow[show.persistentModelID] ?? []
            progress[show.persistentModelID] = show.progressSummary(asOf: now, forEachEpisode: { episodes.forEach($0) })
        }
        return progress
    }

    /// `progressSummary` over the episodes `forEachEpisode` visits: the show's regular episodes, in any order.
    private func progressSummary(asOf now: Date, forEachEpisode: ((Episode) -> Void) -> Void) -> ShowProgress {
        var aired = 0, watchedAired = 0, watchedAny = 0
        var next: Episode?
        var nextToAir: Episode?
        var lastWatched: Date?
        forEachEpisode { episode in
            if episode.isWatched { watchedAny += 1 }
            if let date = episode.watchedDate, date > lastWatched ?? .distantPast { lastWatched = date }
            guard episode.hasAired(asOf: now) else {
                if episode.airDate != nil, nextToAir.map({ episode.airsBefore($0) }) ?? true { nextToAir = episode }
                return
            }
            aired += 1
            if episode.isWatched {
                watchedAired += 1
            } else if next.map({ episode.airsBefore($0) }) ?? true {
                next = episode
            }
        }
        let status: WatchStatus = if isAbandoned {
            .abandoned
        } else if watchedAired == 0 {
            watchedAny > 0 ? .watching : .notWatched
        } else {
            watchedAired == aired ? .watched : .watching
        }
        return ShowProgress(status: status, fraction: aired == 0 ? 0 : Double(watchedAired) / Double(aired),
                            nextEpisode: next, nextEpisodeToAir: nextToAir, airedCount: aired, watchedAiredCount: watchedAired,
                            lastWatched: lastWatched)
    }

    /// The first aired, unwatched regular episode, in airing order.
    func nextEpisodeToWatch(asOf now: Date = .now) -> Episode? {
        var next: Episode?
        forEachRegularEpisode { episode in
            guard !episode.isWatched, episode.hasAired(asOf: now) else { return }
            if next.map({ episode.airsBefore($0) }) ?? true { next = episode }
        }
        return next
    }

    /// The next episode that hasn't aired yet.
    func nextEpisodeToAir(asOf now: Date = .now) -> Episode? {
        var next: Episode?
        forEachRegularEpisode { episode in
            guard episode.airDate != nil, !episode.hasAired(asOf: now) else { return }
            if next.map({ episode.airsBefore($0) }) ?? true { next = episode }
        }
        return next
    }

    /// Most recent date any episode was marked watched, used to order "Next to Watch".
    var lastWatchedDate: Date? {
        var latest: Date?
        forEachRegularEpisode { if let date = $0.watchedDate, date > latest ?? .distantPast { latest = date } }
        return latest
    }

    /// Visits every regular episode (specials excluded) in no particular order. Cheaper than `regularEpisodes`,
    /// which sorts the seasons and each season's episodes and builds a new array.
    func forEachRegularEpisode(_ body: (Episode) -> Void) {
        for season in seasons ?? [] where season.seasonNumber > 0 {
            for episode in season.episodes ?? [] { body(episode) }
        }
    }
}

extension Episode {
    /// Airing order: season, then episode number.
    func airsBefore(_ other: Episode) -> Bool {
        (seasonNumber, episodeNumber) < (other.seasonNumber, other.episodeNumber)
    }
}

/// See `TVShow.progressSummary(asOf:)`.
public struct ShowProgress {
    public let status: WatchStatus
    /// Fraction of aired regular episodes watched (0...1).
    public let fraction: Double
    /// The first aired, unwatched regular episode.
    public let nextEpisode: Episode?
    /// The next regular episode that hasn't aired yet.
    public let nextEpisodeToAir: Episode?
    public let airedCount: Int
    public let watchedAiredCount: Int
    /// Most recent date any regular episode was marked watched.
    public let lastWatched: Date?

    /// Aired regular episodes not watched yet.
    public var remainingCount: Int { airedCount - watchedAiredCount }
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
