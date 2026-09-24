import SwiftData
import SwiftUI
import ToWatchCore

/// The next aired, unwatched episode of each show you're following, most recently active first.
struct NextToWatchView: View {
    @Environment(AppState.self) private var appState
    @Query private var shows: [TVShow]

    var body: some View {
        let now = Date.now
        let queue = shows
            .filter { !$0.isAbandoned && $0.nextEpisodeToWatch(asOf: now) != nil }
            // Shows you've started come first, then untouched ones by date added.
            .sorted { lhs, rhs in
                switch (lhs.lastWatchedDate, rhs.lastWatchedDate) {
                case let (l?, r?): l > r
                case (.some, nil): true
                case (nil, .some): false
                case (nil, nil): lhs.addedDate > rhs.addedDate
                }
            }

        Group {
            if queue.isEmpty {
                ContentUnavailableView("You're All Caught Up", systemImage: "checkmark.seal",
                                       description: Text("There are no episodes left to watch."))
            } else {
                List(queue) { show in
                    if let episode = show.nextEpisodeToWatch(asOf: now) {
                        NextEpisodeRow(show: show, episode: episode, remaining: show.airedEpisodes(asOf: now).count { !$0.isWatched })
                    }
                }
            }
        }
        .navigationTitle("Next to Watch")
        .toolbar {
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await appState.refreshLibrary(force: true) }
                }
                .disabled(appState.isRefreshing)
            }
        }
    }
}

private struct NextEpisodeRow: View {
    @Environment(AppState.self) private var appState
    let show: TVShow
    let episode: Episode
    let remaining: Int

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
                            Text(remaining == 1 ? "1 episode left" : "\(remaining) episodes left")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        ProgressView(value: show.progress())
                            .frame(maxWidth: 240)
                    }
                }
            }
            Spacer()
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
