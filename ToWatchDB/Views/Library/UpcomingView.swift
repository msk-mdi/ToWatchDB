import SwiftData
import SwiftUI
import ToWatchCore

/// Movies and episodes in your library releasing today or later, grouped by day.
struct UpcomingView: View {
    @Query private var movies: [Movie]
    @Query private var shows: [TVShow]

    var body: some View {
        let now = Date.now
        let items = UpcomingService.upcoming(movies: movies, shows: shows, now: now)
        let days = Dictionary(grouping: items) { $0.date.map { UpcomingService.startOfToday($0) } ?? .distantFuture }
            .sorted { $0.key < $1.key }

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
        .navigationTitle("Upcoming")
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
