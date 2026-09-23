import Foundation
import ToWatchCore

/// A TMDB search/trending result that may or may not be in the library yet.
struct MediaSummary: Hashable, Identifiable, Sendable {
    enum Kind: String, Hashable, Sendable, CaseIterable, Identifiable {
        case movie, tv
        var id: Self { self }
        var label: String { self == .movie ? "Movies" : "TV Shows" }
    }

    let kind: Kind
    let tmdbID: Int
    let title: String
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let date: Date?
    let voteAverage: Double?

    var id: String { "\(kind.rawValue)-\(tmdbID)" }

    init(_ movie: TMDBMovieSummary) {
        kind = .movie
        tmdbID = movie.id
        title = movie.title
        overview = movie.overview
        posterPath = movie.posterPath
        backdropPath = movie.backdropPath
        date = TMDBDate.parse(movie.releaseDate)
        voteAverage = movie.voteAverage
    }

    init(_ show: TMDBTVSummary) {
        kind = .tv
        tmdbID = show.id
        title = show.name
        overview = show.overview
        posterPath = show.posterPath
        backdropPath = show.backdropPath
        date = TMDBDate.parse(show.firstAirDate)
        voteAverage = show.voteAverage
    }
}

/// TMDB IDs already in the library, so result cards can show "added" state.
struct LibraryIDs {
    var movies: Set<Int> = []
    var shows: Set<Int> = []

    init(movies: [Movie], shows: [TVShow]) {
        self.movies = Set(movies.map(\.tmdbID))
        self.shows = Set(shows.map(\.tmdbID))
    }

    func contains(_ summary: MediaSummary) -> Bool {
        summary.kind == .movie ? movies.contains(summary.tmdbID) : shows.contains(summary.tmdbID)
    }
}
