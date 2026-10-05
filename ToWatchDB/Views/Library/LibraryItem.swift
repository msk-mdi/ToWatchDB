import Foundation
import SwiftData
import ToWatchCore

/// A movie or show in the library, unified for grids and sorting.
enum LibraryItem: Identifiable, Hashable {
    case movie(Movie)
    case show(TVShow)

    var id: PersistentIdentifier {
        switch self {
        case let .movie(movie): movie.persistentModelID
        case let .show(show): show.persistentModelID
        }
    }

    var title: String {
        switch self {
        case let .movie(movie): movie.title
        case let .show(show): show.name
        }
    }

    var posterPath: String? {
        switch self {
        case let .movie(movie): movie.posterPath
        case let .show(show): show.posterPath
        }
    }

    var releaseDate: Date? {
        switch self {
        case let .movie(movie): movie.releaseDate
        case let .show(show): show.firstAirDate
        }
    }

    var addedDate: Date {
        switch self {
        case let .movie(movie): movie.addedDate
        case let .show(show): show.addedDate
        }
    }

    var isInBacklog: Bool {
        switch self {
        case let .movie(movie): movie.isInBacklog
        case let .show(show): show.isInBacklog
        }
    }

    var userRating: Double? {
        switch self {
        case let .movie(movie): movie.userRating
        case let .show(show): show.userRating
        }
    }

    /// When the item was last watched: a movie's watch date, or a show's most recent episode.
    var lastWatched: Date? {
        switch self {
        case let .movie(movie): movie.watchedDate
        case let .show(show): show.lastWatchedDate
        }
    }

    var libraryTitle: LibraryTitle {
        switch self {
        case let .movie(movie): .movie(movie)
        case let .show(show): .show(show)
        }
    }

    var spaces: [Space] { libraryTitle.spaces }
    var tags: [MediaTag] { libraryTitle.tags }

    func watchStatus(asOf now: Date = .now) -> WatchStatus {
        switch self {
        case let .movie(movie): movie.watchStatus
        case let .show(show): show.watchStatus(asOf: now)
        }
    }
}

enum LibraryScope: Hashable {
    case all, movies, shows, backlog, watched
    case space(UUID), tag(UUID), smartList(UUID)

    /// Scopes offered by the iPhone segmented control.
    static let fixed: [LibraryScope] = [.all, .movies, .shows, .backlog, .watched]

    /// Title for fixed scopes; collection scopes are named by their model.
    var title: String {
        switch self {
        case .all: "All"
        case .movies: "Movies"
        case .shows: "TV Shows"
        case .backlog: "Backlog"
        case .watched: "Watched"
        case .space: "Space"
        case .tag: "Tag"
        case .smartList: "Smart List"
        }
    }

    var defaultSort: LibrarySort { self == .watched ? .lastWatched : .added }

    /// Dropping a title here adds it to the library (and the backlog, for Backlog; the space, for a space).
    /// Watched and smart lists don't accept drops: their contents follow from rules, not placement.
    var acceptsDrops: Bool {
        switch self {
        case .watched, .smartList: false
        default: true
        }
    }

    /// Short label for the iPhone segmented control.
    var shortTitle: String { self == .shows ? "TV" : title }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case added, title, release, rating, lastWatched
    var id: Self { self }

    var label: String {
        switch self {
        case .added: "Date Added"
        case .title: "Title"
        case .release: "Release Date"
        case .rating: "Your Rating"
        case .lastWatched: "Last Watched"
        }
    }

    /// Ties (same rating, no release date, never watched…) fall back to title order, so the grid doesn't
    /// reshuffle those titles every time it redraws: @Query results come back in no particular order.
    func areInOrder(_ lhs: LibraryItem, _ rhs: LibraryItem) -> Bool {
        // The title comparison is locale-aware and comparatively slow, so it only runs on ties.
        func byTitle() -> Bool { lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending }
        func ordered<T: Comparable>(_ l: T, _ r: T) -> Bool { l == r ? byTitle() : l > r }
        switch self {
        case .added: return ordered(lhs.addedDate, rhs.addedDate)
        case .title: return byTitle()
        case .release: return ordered(lhs.releaseDate ?? .distantPast, rhs.releaseDate ?? .distantPast)
        case .rating: return ordered(lhs.userRating ?? -1, rhs.userRating ?? -1)
        case .lastWatched: return ordered(lhs.lastWatched ?? .distantPast, rhs.lastWatched ?? .distantPast)
        }
    }
}
