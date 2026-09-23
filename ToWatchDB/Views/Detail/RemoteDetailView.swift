import SwiftData
import SwiftUI
import ToWatchCore

/// Detail for a TMDB result. Shows the library detail once the title is added; otherwise a preview with "Add".
struct RemoteDetailView: View {
    let summary: MediaSummary
    @Query private var movies: [Movie]
    @Query private var shows: [TVShow]

    init(summary: MediaSummary) {
        self.summary = summary
        let id = summary.tmdbID
        _movies = Query(filter: #Predicate<Movie> { $0.tmdbID == id })
        _shows = Query(filter: #Predicate<TVShow> { $0.tmdbID == id })
    }

    var body: some View {
        switch summary.kind {
        case .movie:
            if let movie = movies.first { MovieDetailView(movie: movie) } else { RemotePreview(summary: summary) }
        case .tv:
            if let show = shows.first { TVShowDetailView(show: show) } else { RemotePreview(summary: summary) }
        }
    }
}

private struct RemotePreview: View {
    @Environment(AppState.self) private var appState
    let summary: MediaSummary

    @State private var movie: TMDBMovieDetail?
    @State private var show: TMDBTVDetail?
    @State private var isAdding = false

    var body: some View {
        DetailLayout(
            title: summary.title,
            subtitle: subtitle,
            posterPath: summary.posterPath,
            backdropPath: summary.backdropPath,
            tagline: movie?.tagline ?? show?.tagline,
            overview: movie?.overview ?? show?.overview ?? summary.overview,
            genres: (movie?.genres ?? show?.genres ?? []).map(\.name),
            cast: PersonCredit.cast(from: movie?.credits ?? show?.credits)
        ) {
            HStack(spacing: 12) {
                Button { add(backlog: false) } label: {
                    Label("Add to Library", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                Button { add(backlog: true) } label: {
                    Label("Add to Backlog", systemImage: "tray.and.arrow.down")
                }
                if isAdding { ProgressView().controlSize(.small) }
                Spacer()
                ExternalLinks(kind: summary.kind, tmdbID: summary.tmdbID,
                              trailerKey: (movie?.videos ?? show?.videos)?.bestTrailerKey, imdbID: movie?.imdbId)
            }
            .disabled(isAdding)
        } extra: {
            EmptyView()
        }
        .navigationTitle(summary.title)
        .task { await load() }
    }

    private var subtitle: String {
        var parts = [summary.kind == .movie ? "Movie" : "TV Show"]
        if let year = summary.date?.yearString { parts.append(year) }
        if let runtime = movie?.runtime, runtime > 0 { parts.append(runtime.runtimeString) }
        if let seasons = show?.numberOfSeasons { parts.append("\(seasons) season\(seasons == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        guard let client = appState.client else { return }
        switch summary.kind {
        case .movie: movie = try? await client.movie(id: summary.tmdbID)
        case .tv: show = try? await client.tvShow(id: summary.tmdbID)
        }
    }

    private func add(backlog: Bool) {
        isAdding = true
        Task {
            await appState.perform { library in
                switch summary.kind {
                case .movie:
                    // Reuse the payload we already have instead of fetching it again.
                    let added = if let movie { library.insertMovie(movie) } else { try await library.addMovie(tmdbID: summary.tmdbID) }
                    if backlog { library.setBacklog(added, true) }
                case .tv:
                    let added = try await library.addShow(tmdbID: summary.tmdbID)
                    if backlog { library.setBacklog(added, true) }
                }
            }
            isAdding = false
        }
    }
}
