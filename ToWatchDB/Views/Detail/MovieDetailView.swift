import SwiftUI
import ToWatchCore

struct MovieDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isActivePage) private var isActivePage
    let movie: Movie

    @State private var showDatePicker = false
    @State private var confirmDelete = false
    @State private var isRefreshing = false

    var body: some View {
        // A sync can delete the title while it's open; a deleted model can't be read.
        if movie.modelContext == nil {
            ContentUnavailableView("Removed from Library", systemImage: "trash",
                                   description: Text("This title was removed on another device."))
        } else {
            page
                .task(id: movie.persistentModelID) { await appState.library.refreshIMDbRatingIfDue(movie) }
        }
    }

    @ViewBuilder
    private var page: some View {
        DetailLayout(
            title: movie.title,
            subtitle: subtitle,
            posterPath: movie.posterPath,
            backdropPath: movie.backdropPath,
            tagline: movie.tagline,
            overview: movie.overview,
            genres: movie.genres,
            facts: facts,
            cast: movie.cast
        ) {
            VStack(alignment: .leading, spacing: 14) {
                ActionBar {
                    watchedButton
                } toggles: {
                    Toggle(isOn: Binding(get: { movie.isInBacklog }, set: { appState.library.setBacklog(movie, $0) })) {
                        Label("Backlog", systemImage: "tray.full")
                    }
                    Toggle(isOn: Binding(get: { movie.isFavorite }, set: { appState.library.setFavorite(movie, $0) })) {
                        Label("Favorite", systemImage: movie.isFavorite ? "heart.fill" : "heart")
                    }
                } trailing: {
                    RatingView(rating: movie.userRating) { appState.library.setRating(movie, $0) }
                } request: {
                    SeerrRequestButton(kind: .movie, tmdbID: movie.tmdbID, title: movie.title)
                }
                ExternalLinks(kind: .movie, tmdbID: movie.tmdbID, trailerKey: movie.trailerKey,
                              imdbID: movie.imdbID, homepage: movie.homepage)
            }
        } extra: {
            WhereToWatchSection(kind: .movie, tmdbID: movie.tmdbID)
            CollectionsSection(title: .movie(movie))
            NotesSection(notes: movie.notes ?? []) { appState.library.addNote($0, to: movie) }
        }
        .pageTitle(movie.title)
        .focusedSceneValue(\.focusedTitle, isActivePage ? .movie(movie) : nil)
        .hasOwnRefreshButton()
        .pageToolbar {
            ToolbarItemGroup {
                Button("Refresh", systemImage: "arrow.clockwise") { refresh() }
                    .disabled(isRefreshing)
                Button("Remove from Library", systemImage: "trash") { confirmDelete = true }
            }
        }
        .sheet(isPresented: $showDatePicker) {
            WatchDateSheet(title: movie.title) { appState.library.setWatched(movie, true, on: $0) }
        }
        .confirmationDialog("Remove “\(movie.title)” from your library?", isPresented: $confirmDelete) {
            Button("Remove", role: .destructive) {
                dismiss()
                appState.library.delete(movie)
            }
        } message: {
            Text("Your watch history, rating, and notes for this movie will be deleted.")
        }
    }

    @ViewBuilder
    private var watchedButton: some View {
        if movie.isWatched {
            Menu {
                Button("Change Date…") { showDatePicker = true }
                Button("Mark as Not Watched", role: .destructive) { appState.library.setWatched(movie, false) }
            } label: {
                Label(movie.watchedDate.map { "Watched \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "Watched",
                      systemImage: "checkmark.circle.fill")
            } primaryAction: {
                appState.library.setWatched(movie, false)
            }
            .tint(.green)
        } else {
            Menu {
                Button("Watched on…") { showDatePicker = true }
            } label: {
                Label("Mark Watched", systemImage: "checkmark.circle")
            } primaryAction: {
                appState.library.setWatched(movie, true)
            }
            .disabled(!movie.isReleased())
            .help(movie.isReleased() ? "Mark as watched today" : "Not released yet")
        }
    }

    private var subtitle: String {
        var parts = ["Movie"]
        if let date = movie.releaseDate { parts.append(date.yearString) }
        if let runtime = movie.runtime { parts.append(runtime.runtimeString) }
        if let rating = movie.imdbRating { parts.append("IMDb \(rating.ratingString)") }
        if let vote = movie.voteAverage, vote > 0 { parts.append("TMDB \(vote.ratingString)") }
        return parts.joined(separator: " · ")
    }

    private var facts: [(String, String)] {
        var facts: [(String, String)] = []
        if let date = movie.releaseDate { facts.append(("Release", date.tmdbDayString)) }
        if let status = movie.releaseStatus { facts.append(("Status", status)) }
        let directors = movie.directors.map(\.name)
        if !directors.isEmpty { facts.append((directors.count == 1 ? "Director" : "Directors", directors.formatted())) }
        if let original = movie.originalTitle, original != movie.title { facts.append(("Original Title", original)) }
        facts.append(("Added", movie.addedDate.formatted(date: .abbreviated, time: .omitted)))
        return facts
    }

    private func refresh() {
        isRefreshing = true
        Task {
            await appState.perform { try await $0.refresh(movie) }
            isRefreshing = false
        }
    }
}
