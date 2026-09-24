import SwiftUI
import ToWatchCore

struct TVShowDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let show: TVShow

    @State private var selectedSeason: Int?
    @State private var confirmDelete = false
    @State private var isRefreshing = false
    @State private var notesEpisode: Episode?

    var body: some View {
        DetailLayout(
            title: show.name,
            subtitle: subtitle,
            posterPath: show.posterPath,
            backdropPath: show.backdropPath,
            tagline: show.tagline,
            overview: show.overview,
            genres: show.genres,
            facts: facts,
            cast: show.cast
        ) {
            VStack(alignment: .leading, spacing: 14) {
                progressSummary
                ActionBar {
                    Menu {
                        Button("Mark All Aired Episodes Watched") { appState.library.setWatched(show, true) }
                        Button("Mark All as Not Watched", role: .destructive) { appState.library.setWatched(show, false) }
                    } label: {
                        Label("Watched", systemImage: "checkmark.circle")
                    }
                    .fixedSize()
                    Toggle(isOn: Binding(get: { show.isInBacklog }, set: { appState.library.setBacklog(show, $0) })) {
                        Label("Backlog", systemImage: "tray.full")
                    }
                    .toggleStyle(.button)
                    Toggle(isOn: Binding(get: { show.isFavorite }, set: { appState.library.setFavorite(show, $0) })) {
                        Label("Favorite", systemImage: show.isFavorite ? "heart.fill" : "heart")
                    }
                    .toggleStyle(.button)
                    Toggle(isOn: Binding(get: { show.isAbandoned }, set: { appState.library.setAbandoned(show, $0) })) {
                        Label("Abandoned", systemImage: "xmark.circle")
                    }
                    .toggleStyle(.button)
                    RatingView(rating: show.userRating) { appState.library.setRating(show, $0) }
                        .font(.title3)
                        .padding(.leading, 8)
                }
                ExternalLinks(kind: .tv, tmdbID: show.tmdbID, trailerKey: show.trailerKey, homepage: show.homepage)
            }
        } extra: {
            seasonsSection
            CollectionsSection(title: .show(show))
            NotesSection(notes: show.notes ?? []) { appState.library.addNote($0, to: show) }
        }
        .navigationTitle(show.name)
        .focusedSceneValue(\.focusedTitle, .show(show))
        .toolbar {
            ToolbarItemGroup {
                Button("Refresh", systemImage: "arrow.clockwise") { refresh() }
                    .disabled(isRefreshing)
                Button("Remove from Library", systemImage: "trash") { confirmDelete = true }
            }
        }
        .sheet(item: $notesEpisode) { episode in
            EpisodeNotesSheet(episode: episode)
        }
        .confirmationDialog("Remove “\(show.name)” from your library?", isPresented: $confirmDelete) {
            Button("Remove", role: .destructive) {
                dismiss()
                appState.library.delete(show)
            }
        } message: {
            Text("Your watch history, ratings, and notes for this show will be deleted.")
        }
        .onAppear {
            // Open on the season containing the next episode to watch.
            if selectedSeason == nil {
                selectedSeason = show.nextEpisodeToWatch()?.seasonNumber
                    ?? show.sortedSeasons.first { $0.seasonNumber > 0 }?.seasonNumber
                    ?? show.sortedSeasons.first?.seasonNumber
            }
        }
    }

    // MARK: Progress

    private var progressSummary: some View {
        let aired = show.airedEpisodes().count
        let watched = show.airedEpisodes().count { $0.isWatched }
        let status = show.watchStatus()
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(status.label, systemImage: status.symbol).foregroundStyle(status.tint)
                Text("\(watched) of \(aired) aired episodes watched").foregroundStyle(.secondary)
            }
            .font(.callout)
            ProgressView(value: show.progress())
                .frame(maxWidth: 420)
                .tint(status.tint)
            if let next = show.nextEpisodeToWatch() {
                Text("Up next: \(next.code) · \(next.name ?? "")").font(.callout)
            } else if let upcoming = show.nextEpisodeToAir(), let date = upcoming.airDate {
                Text("Next episode \(upcoming.code) airs \(date.tmdbDayString)").font(.callout)
            }
        }
    }

    // MARK: Seasons

    @ViewBuilder
    private var seasonsSection: some View {
        let seasons = show.sortedSeasons
        if !seasons.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Text("Episodes").font(.title3.bold())
                        Spacer()
                        seasonControls(seasons)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Episodes").font(.title3.bold())
                        HStack { seasonControls(seasons) }
                    }
                }

                if let season = currentSeason {
                    LazyVStack(spacing: 0) {
                        ForEach(season.sortedEpisodes) { episode in
                            EpisodeRow(episode: episode, onNotes: { notesEpisode = episode })
                            Divider()
                        }
                    }
                    .frame(maxWidth: 900)
                }
            }
        }
    }

    @ViewBuilder
    private func seasonControls(_ seasons: [Season]) -> some View {
        Picker("Season", selection: $selectedSeason) {
            ForEach(seasons) { season in
                Text(season.displayName).tag(Optional(season.seasonNumber))
            }
        }
        .fixedSize()
        if let season = currentSeason {
            Button(season.isFullyWatched ? "Mark Season Unwatched" : "Mark Season Watched") {
                appState.library.setWatched(season, !season.isFullyWatched)
            }
            .disabled(season.airedEpisodes().isEmpty && !season.isFullyWatched)
        }
    }

    private var currentSeason: Season? {
        show.sortedSeasons.first { $0.seasonNumber == selectedSeason }
    }

    private var subtitle: String {
        var parts = ["TV Show"]
        if let first = show.firstAirDate {
            let end = show.isOngoing ? "" : (show.lastAirDate?.yearString ?? "")
            parts.append(end.isEmpty || end == first.yearString ? first.yearString : "\(first.yearString)–\(end)")
        }
        if let seasons = show.numberOfSeasons { parts.append("\(seasons) season\(seasons == 1 ? "" : "s")") }
        if let vote = show.voteAverage, vote > 0 { parts.append("TMDB \(vote.formatted(.number.precision(.fractionLength(1))))") }
        return parts.joined(separator: " · ")
    }

    private var facts: [(String, String)] {
        var facts: [(String, String)] = []
        if let status = show.showStatus { facts.append(("Status", status)) }
        if !show.networks.isEmpty { facts.append(("Network", show.networks.formatted())) }
        let creators = show.creators.map(\.name)
        if !creators.isEmpty { facts.append(("Created by", creators.formatted())) }
        if let runtime = show.episodeRuntime { facts.append(("Episode Length", runtime.runtimeString)) }
        if let original = show.originalName, original != show.name { facts.append(("Original Title", original)) }
        facts.append(("Added", show.addedDate.formatted(date: .abbreviated, time: .omitted)))
        return facts
    }

    private func refresh() {
        isRefreshing = true
        Task {
            await appState.perform { try await $0.refresh(show) }
            isRefreshing = false
        }
    }
}

private struct EpisodeRow: View {
    @Environment(AppState.self) private var appState
    let episode: Episode
    let onNotes: () -> Void

    var body: some View {
        let aired = episode.hasAired()
        HStack(alignment: .top, spacing: 12) {
            Button {
                appState.library.setWatched(episode, !episode.isWatched)
            } label: {
                Image(systemName: episode.isWatched ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(episode.isWatched ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!aired && !episode.isWatched)
            .help(episode.isWatched ? "Mark as not watched" : "Mark as watched")
            .accessibilityLabel(episode.isWatched ? "Watched" : "Not watched")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(episode.episodeNumber).").monospacedDigit().foregroundStyle(.secondary)
                    Text(episode.name ?? "Episode \(episode.episodeNumber)").fontWeight(.medium)
                    if !(episode.notes ?? []).isEmpty {
                        Image(systemName: "note.text").foregroundStyle(.secondary).font(.caption)
                    }
                }
                if let overview = episode.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                if let date = episode.airDate {
                    Text(date.tmdbDayString)
                        .foregroundStyle(aired ? Color.secondary : Color.orange)
                } else {
                    Text("TBA").foregroundStyle(.orange)
                }
                if let runtime = episode.runtime { Text(runtime.runtimeString).foregroundStyle(.tertiary) }
            }
            .font(.caption)
        }
        .padding(.vertical, 8)
        .opacity(aired || episode.isWatched ? 1 : 0.6)
        .contentShape(.rect)
        .contextMenu {
            if episode.isWatched {
                Button("Mark as Not Watched") { appState.library.setWatched(episode, false) }
            } else {
                Button("Mark as Watched") { appState.library.setWatched(episode, true) }.disabled(!aired)
                Button("Mark Watched Up to Here") { appState.library.markWatchedUpTo(episode) }.disabled(!aired)
            }
            Divider()
            Button("Notes…", systemImage: "note.text", action: onNotes)
        }
    }
}

private struct EpisodeNotesSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let episode: Episode

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(episode.show?.name ?? "").font(.caption).foregroundStyle(.secondary)
                Text("\(episode.code) · \(episode.name ?? "")").font(.headline)
            }
            HStack {
                Text("Rating")
                RatingView(rating: episode.userRating) { appState.library.setRating(episode, $0) }
            }
            ScrollView {
                NotesSection(notes: episode.notes ?? []) { appState.library.addNote($0, to: episode) }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 360)
        #else
        .presentationDetents([.medium, .large])
        #endif
    }
}
