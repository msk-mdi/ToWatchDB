import SwiftData
import SwiftUI
import ToWatchCore

/// The next aired, unwatched episode of each show you're following, most recently active first.
struct NextToWatchView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.isActivePage) private var isActive
    @Query private var shows: [TVShow]

    var body: some View {
        // Hidden (kept alive on Mac): show the last queue instead of recomputing after every save.
        // Keyed by day: an episode airing today joins the queue after midnight, not at the next save.
        let queue = appState.cached("next-to-watch-\(Calendar.current.startOfDay(for: .now))", allowStale: !isActive) {
            Self.queue(shows, progress: appState.showProgress())
        }

        Group {
            if queue.isEmpty {
                ContentUnavailableView("You're All Caught Up", systemImage: "checkmark.seal",
                                       description: Text("There are no episodes left to watch."))
            } else {
                RowList {
                    ForEach(queue, id: \.show.persistentModelID) { entry in
                        NextEpisodeRow(show: entry.show, episode: entry.episode, progress: entry.progress)
                            .rowListRow()
                    }
                }
            }
        }
        .pageTitle("Next to Watch")
        #if os(iOS)
        // On Mac the window has the Refresh button (see RootView).
        .toolbar {
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await appState.refreshLibrary(force: true) }
                }
                .disabled(appState.isRefreshing)
            }
        }
        #endif
    }

    private struct Entry {
        let show: TVShow
        let episode: Episode
        let progress: ShowProgress
    }

    /// Shows you've started come first, most recently watched first, then untouched ones by date added.
    /// Uses the shared per-show progress, so the sort compares precomputed dates.
    private static func queue(_ shows: [TVShow], progress: [PersistentIdentifier: ShowProgress]) -> [Entry] {
        shows
            .compactMap { show -> Entry? in
                guard !show.isAbandoned else { return nil }
                let progress = progress[show.persistentModelID] ?? show.progressSummary()
                guard let episode = progress.nextEpisode else { return nil }
                return Entry(show: show, episode: episode, progress: progress)
            }
            .sorted { lhs, rhs in
                switch (lhs.progress.lastWatched, rhs.progress.lastWatched) {
                case let (l?, r?): l > r
                case (.some, nil): true
                case (nil, .some): false
                case (nil, nil): lhs.show.addedDate > rhs.show.addedDate
                }
            }
    }
}

private struct NextEpisodeRow: View {
    @Environment(AppState.self) private var appState
    let show: TVShow
    let episode: Episode
    let progress: ShowProgress

    var body: some View {
        HStack(spacing: 14) {
            NavigationLink(value: show) {
                HStack(spacing: 14) {
                    PosterImage(path: show.posterPath, size: .small, cornerRadius: 6)
                        .frame(width: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(show.name).font(.headline)
                        Text("\(episode.code) · \(episode.name ?? "Episode \(episode.episodeNumber)")")
                        HStack(spacing: 8) {
                            if let date = episode.airDate { Text(date.tmdbDayString) }
                            Text(progress.remainingCount == 1 ? "1 episode left" : "\(progress.remainingCount) episodes left")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        ProgressView(value: progress.fraction)
                            .frame(maxWidth: 240)
                    }
                }
                #if os(macOS)
                // The whole highlighted row opens the show, not just its text and poster.
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                #endif
            }
            #if os(macOS)
            // Outside a List, a link draws as a bordered button.
            .buttonStyle(.plain)
            #endif
            #if os(iOS)
            Spacer()
            #endif
            Button {
                markWatched()
            } label: {
                #if os(iOS)
                Image(systemName: "checkmark.circle").font(.title2)
                #else
                Label("Watched", systemImage: "checkmark.circle")
                #endif
            }
            // Borderless keeps the button tappable on its own inside an iOS list row.
            .buttonStyle(.borderless)
            .help("Mark \(episode.code) as watched")
            .accessibilityLabel("Mark \(episode.code) as watched")
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .leading) {
            Button("Watched", systemImage: "checkmark", action: markWatched).tint(.green)
        }
    }

    private func markWatched() {
        withAnimation { appState.library.setWatched(episode, true) }
    }
}
