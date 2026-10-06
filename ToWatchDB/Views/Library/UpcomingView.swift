import SwiftData
import SwiftUI
import ToWatchCore

/// Movies and episodes in your library releasing today or later, grouped by day.
struct UpcomingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.isActivePage) private var isActive

    var body: some View {
        let now = Date.now
        // The store returns only future titles and episodes. Cached per save and day (reading the cache redraws
        // the page after each save); a hidden page keeps the last list.
        let (items, days) = appState.cached("upcoming-\(UpcomingService.startOfToday(now))", allowStale: !isActive) {
            let items = UpcomingService.upcoming(in: appState.container.mainContext, now: now)
            let days = Dictionary(grouping: items) { $0.date.map { UpcomingService.startOfToday($0) } ?? .distantFuture }
                .sorted { $0.key < $1.key }
            return (items, days)
        }

        Group {
            if items.isEmpty {
                ContentUnavailableView("Nothing Upcoming", systemImage: "calendar",
                                       description: Text("New episodes and releases from your library show up here."))
            } else {
                List {
                    ForEach(days, id: \.key) { day, dayItems in
                        Section {
                            ForEach(dayItems) { UpcomingRow(item: $0) }
                        } header: {
                            HStack {
                                Text(day.tmdbDayString)
                                Spacer()
                                Text(relative(day, now: now)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .pageTitle("Upcoming")
        .pageToolbar {
            // Also keeps the Mac toolbar from collapsing: a List page with an empty toolbar
            // made the whole window shift up when you switched to it.
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await appState.refreshLibrary(force: true) }
                }
                .disabled(appState.isRefreshing)
            }
        }
    }

    private func relative(_ day: Date, now: Date) -> String {
        switch UpcomingService.daysUntil(day, now: now) {
        case 0: "Today"
        case 1: "Tomorrow"
        case let days: "In \(days) days"
        }
    }
}

private struct UpcomingRow: View {
    let item: UpcomingItem

    var body: some View {
        switch item {
        case let .movie(movie):
            NavigationLink(value: movie) {
                row(poster: movie.posterPath, title: movie.title, detail: "Movie release", symbol: "film")
            }
        case let .episode(episode):
            if let show = episode.show {
                NavigationLink(value: show) {
                    row(poster: show.posterPath, title: show.name,
                        detail: "\(episode.code) · \(episode.name ?? "Episode \(episode.episodeNumber)")", symbol: "tv")
                }
            }
        }
    }

    private func row(poster: String?, title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            PosterImage(path: poster, size: .small, cornerRadius: 5)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Label(detail, systemImage: symbol)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
