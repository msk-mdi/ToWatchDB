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

    func watchStatus(asOf now: Date = .now) -> WatchStatus {
        switch self {
        case let .movie(movie): movie.watchStatus
        case let .show(show): show.watchStatus(asOf: now)
        }
    }
}

enum LibraryScope: Hashable {
    case all, movies, shows, backlog, watched

    var title: String {
        switch self {
        case .all: "All"
        case .movies: "Movies"
        case .shows: "TV Shows"
        case .backlog: "Backlog"
        case .watched: "Watched"
        }
    }
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

    func areInOrder(_ lhs: LibraryItem, _ rhs: LibraryItem) -> Bool {
        switch self {
        case .added: lhs.addedDate > rhs.addedDate
        case .title: lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        case .release: (lhs.releaseDate ?? .distantPast) > (rhs.releaseDate ?? .distantPast)
        case .rating: (lhs.userRating ?? -1) > (rhs.userRating ?? -1)
        case .lastWatched: (lhs.lastWatched ?? .distantPast) > (rhs.lastWatched ?? .distantPast)
        }
    }
}
