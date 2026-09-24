import Foundation
import SwiftData

// Ways to organize the library: spaces (curated collections), tags (labels), and smart lists (saved filters).
// Same CloudKit rules as the other models. Each has a stable `uuid` so smart-list rules and
// navigation can refer to it without depending on SwiftData's store-specific identifiers.

/// A curated collection, such as "Family Night" or "Oscar Winners", with an icon and a color.
@Model
public final class Space {
    public var uuid: UUID = UUID()
    public var name: String = ""
    public var symbolName: String = "star"
    public var colorName: String = "blue"
    public var createdAt: Date = Date.now

    @Relationship(deleteRule: .nullify, inverse: \Movie.spaces)
    public var movies: [Movie]? = []

    @Relationship(deleteRule: .nullify, inverse: \TVShow.spaces)
    public var shows: [TVShow]? = []

    public init(name: String, symbolName: String = "star", colorName: String = "blue") {
        self.name = name
        self.symbolName = symbolName
        self.colorName = colorName
    }

    public var itemCount: Int { (movies?.count ?? 0) + (shows?.count ?? 0) }
}

/// A colored label. Called MediaTag to stay clear of Swift Testing's `Tag`.
@Model
public final class MediaTag {
    public var uuid: UUID = UUID()
    public var name: String = ""
    public var colorName: String = "gray"
    public var createdAt: Date = Date.now

    @Relationship(deleteRule: .nullify, inverse: \Movie.tags)
    public var movies: [Movie]? = []

    @Relationship(deleteRule: .nullify, inverse: \TVShow.tags)
    public var shows: [TVShow]? = []

    public init(name: String, colorName: String = "gray") {
        self.name = name
        self.colorName = colorName
    }

    public var itemCount: Int { (movies?.count ?? 0) + (shows?.count ?? 0) }
}

/// A saved filter over the library. Rules are stored as JSON so new criteria don't need a schema change.
@Model
public final class SmartList {
    public var uuid: UUID = UUID()
    public var name: String = ""
    public var symbolName: String = "wand.and.stars"
    public var colorName: String = "purple"
    public var createdAt: Date = Date.now
    public var rulesData: Data?

    public init(name: String, rules: SmartListRules = SmartListRules()) {
        self.name = name
        self.rules = rules
    }

    public var rules: SmartListRules {
        get { rulesData.flatMap { try? JSONDecoder().decode(SmartListRules.self, from: $0) } ?? SmartListRules() }
        set { rulesData = try? JSONEncoder().encode(newValue) }
    }
}

/// Criteria for a smart list. Every set criterion must match (AND); within a set, any value matches (OR).
/// Empty sets and nil values mean "don't filter on this".
public struct SmartListRules: Codable, Sendable, Hashable {
    public enum Media: String, Codable, Sendable, CaseIterable, Identifiable {
        case all, movies, shows
        public var id: Self { self }
        public var label: String {
            switch self {
            case .all: "Movies & TV Shows"
            case .movies: "Movies"
            case .shows: "TV Shows"
            }
        }
    }

    public var media: Media = .all
    public var statuses: Set<WatchStatus> = []
    public var genres: Set<String> = []
    public var tagIDs: Set<UUID> = []
    public var spaceIDs: Set<UUID> = []
    /// Your rating, 0–10. Unrated titles never match a minimum.
    public var minimumRating: Double?
    public var releasedFrom: Int?
    public var releasedThrough: Int?
    public var backlogOnly = false
    public var favoritesOnly = false

    public init() {}

    public func matches(_ movie: Movie) -> Bool {
        media != .shows
            && matchesCommon(status: movie.watchStatus, genres: movie.genres, tags: movie.tags, spaces: movie.spaces,
                             rating: movie.userRating, date: movie.releaseDate,
                             backlog: movie.isInBacklog, favorite: movie.isFavorite)
    }

    public func matches(_ show: TVShow, now: Date = .now) -> Bool {
        media != .movies
            && matchesCommon(status: show.watchStatus(asOf: now), genres: show.genres, tags: show.tags, spaces: show.spaces,
                             rating: show.userRating, date: show.firstAirDate,
                             backlog: show.isInBacklog, favorite: show.isFavorite)
    }

    private func matchesCommon(status: WatchStatus, genres itemGenres: [String], tags: [MediaTag]?, spaces: [Space]?,
                               rating: Double?, date: Date?, backlog: Bool, favorite: Bool) -> Bool {
        if !statuses.isEmpty, !statuses.contains(status) { return false }
        if !genres.isEmpty, genres.isDisjoint(with: itemGenres) { return false }
        if !tagIDs.isEmpty, tagIDs.isDisjoint(with: (tags ?? []).map(\.uuid)) { return false }
        if !spaceIDs.isEmpty, spaceIDs.isDisjoint(with: (spaces ?? []).map(\.uuid)) { return false }
        if let minimumRating, (rating ?? -1) < minimumRating { return false }
        if releasedFrom != nil || releasedThrough != nil {
            guard let year = date.map(Self.utcYear) else { return false }
            if let releasedFrom, year < releasedFrom { return false }
            if let releasedThrough, year > releasedThrough { return false }
        }
        if backlogOnly, !backlog { return false }
        if favoritesOnly, !favorite { return false }
        return true
    }

    private static func utcYear(_ date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar.component(.year, from: date)
    }
}
