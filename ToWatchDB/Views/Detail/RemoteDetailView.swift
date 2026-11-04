import SwiftData
import SwiftUI
import ToWatchCore

/// Detail for a TMDB result. Shows the library detail once the title is added; otherwise a preview with "Add".
struct RemoteDetailView: View {
    let summary: MediaSummary

    var body: some View {
        // One query, of the summary's kind: both kept a query alive that refetched after every save.
        let id = summary.tmdbID
        switch summary.kind {
        case .movie:
            LibraryOrPreview(summary: summary, predicate: #Predicate<Movie> { $0.tmdbID == id }) { MovieDetailView(movie: $0) }
        case .tv:
            LibraryOrPreview(summary: summary, predicate: #Predicate<TVShow> { $0.tmdbID == id }) { TVShowDetailView(show: $0) }
        }
    }
}

/// The library's title for the summary when there is one, else the preview.
private struct LibraryOrPreview<Model: PersistentModel, Detail: View>: View {
    let summary: MediaSummary
    @ViewBuilder let detail: (Model) -> Detail
    @Query private var titles: [Model]

    init(summary: MediaSummary, predicate: Predicate<Model>, @ViewBuilder detail: @escaping (Model) -> Detail) {
        self.summary = summary
        self.detail = detail
        var descriptor = FetchDescriptor(predicate: predicate)
        descriptor.fetchLimit = 1
        _titles = Query(descriptor)
    }

    var body: some View {
        if let title = titles.first { detail(title) } else { RemotePreview(summary: summary) }
    }
}

private struct RemotePreview: View {
    @Environment(AppState.self) private var appState
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    let summary: MediaSummary

    @State private var movie: TMDBMovieDetail?
    @State private var show: TMDBTVDetail?
    @State private var imdbRating: IMDbRating?
    @State private var isAdding = false

    var body: some View {
        DetailLayout(
            title: summary.title,
            subtitle: subtitle,
            // Fall back to the fetched detail: summaries restored from a window reference carry no artwork.
            posterPath: summary.posterPath ?? movie?.posterPath ?? show?.posterPath,
            backdropPath: summary.backdropPath ?? movie?.backdropPath ?? show?.backdropPath,
            tagline: movie?.tagline ?? show?.tagline,
            overview: movie?.overview ?? show?.overview ?? summary.overview,
            genres: (movie?.genres ?? show?.genres ?? []).map(\.name),
            cast: PersonCredit.cast(from: movie?.credits ?? show?.credits)
        ) {
            if isCompact {
                // iPhone: two full-width buttons, then the links, instead of everything squeezed on one line.
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Button { add(backlog: false) } label: {
                            Label("Add to Library", systemImage: isAdding ? "hourglass" : "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        Button { add(backlog: true) } label: {
                            Label("Backlog", systemImage: "tray.and.arrow.down")
                        }
                        .buttonStyle(.bordered)
                    }
                    .labelStyle(WideLabelStyle())
                    .controlSize(.large)
                    .disabled(isAdding)
                    seerrButton
                    links
                }
            } else {
                HStack(spacing: 12) {
                    Button { add(backlog: false) } label: {
                        Label("Add to Library", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    Button { add(backlog: true) } label: {
                        Label("Add to Backlog", systemImage: "tray.and.arrow.down")
                    }
                    seerrButton
                    if isAdding { ProgressView().controlSize(.small) }
                    Spacer()
                    links
                }
                .disabled(isAdding)
            }
        } extra: {
            WhereToWatchSection(kind: summary.kind, tmdbID: summary.tmdbID)
        }
        .pageTitle(summary.title)
        // Again once a token is added (without one, the page stayed empty) or the language changes.
        .task(id: [String(appState.tokenVersion), appState.language]) { await load() }
    }

    private var links: some View {
        ExternalLinks(kind: summary.kind, tmdbID: summary.tmdbID,
                      trailerKey: (movie?.videos ?? show?.videos)?.bestTrailerKey, imdbID: imdbID)
    }

    private var seerrButton: some View {
        SeerrRequestButton(kind: summary.kind, tmdbID: summary.tmdbID, title: summary.title)
    }

    private var imdbID: String? { movie?.imdbId ?? show?.externalIds?.imdbId }

    private var isCompact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    private var subtitle: String {
        var parts = [summary.kind == .movie ? "Movie" : "TV Show"]
        if let year = summary.date?.yearString { parts.append(year) }
        if let runtime = movie?.runtime, runtime > 0 { parts.append(runtime.runtimeString) }
        if let seasons = show?.numberOfSeasons { parts.append("\(seasons) season\(seasons == 1 ? "" : "s")") }
        if let imdbRating { parts.append("IMDb \(imdbRating.value.ratingString)") }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        guard let client = appState.client else { return }
        let id = summary.tmdbID
        switch summary.kind {
        case .movie: movie = try? await appState.cachedResponse("movie-\(id)") { try await client.movie(id: id) }
        case .tv: show = try? await appState.cachedResponse("tv-\(id)") { try await client.tvShow(id: id) }
        }
        if let imdbID, let imdb = appState.imdb {
            imdbRating = try? await appState.cachedResponse("imdb-\(imdbID)") {
                try await imdb.ratings(for: [imdbID])[imdbID] ?? nil
            }
        }
    }

    private func add(backlog: Bool) {
        isAdding = true
        Task {
            await appState.perform { library in
                // Reuse the detail this page already fetched: a movie needs nothing more, a show only its seasons.
                switch summary.kind {
                case .movie:
                    let added = if let movie { library.insertMovie(movie) } else { try await library.addMovie(tmdbID: summary.tmdbID) }
                    if backlog, added.isLive { library.setBacklog(added, true) }
                    if movie != nil { library.refreshIMDbRatingsLater(movies: [added]) }
                case .tv:
                    let added = if let show { try await library.addShow(show) } else { try await library.addShow(tmdbID: summary.tmdbID) }
                    if backlog, added.isLive { library.setBacklog(added, true) }
                }
            }
            isAdding = false
        }
    }
}
