import Charts
import SwiftData
import SwiftUI
import ToWatchCore

/// Watch statistics for a period, with activity, top genres and actors, highlights, and a year comparison.
struct StatsView: View {
    @Environment(AppState.self) private var appState
    @Query private var movies: [Movie]
    @Query private var shows: [TVShow]

    @State private var period: StatsPeriod = .year(Calendar.current.component(.year, from: .now))
    @State private var comparedYear: Int?
    @State private var isShowingReview = false

    var body: some View {
        let stats = StatsService.stats(movies: movies, shows: shows, period: period)
        let years = StatsService.watchYears(movies: movies, shows: shows)

        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if stats.isEmpty {
                    ContentUnavailableView("Nothing Watched \(periodPhrase)", systemImage: "chart.bar",
                                           description: Text("Mark movies and episodes as watched to see your stats."))
                        .padding(.top, 40)
                } else {
                    SummaryTiles(stats: stats)
                    ActivityChart(stats: stats)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 24) {
                            GenreChart(genres: stats.topGenres).frame(maxWidth: .infinity, alignment: .topLeading)
                            ActorList(actors: stats.topActors).frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        .frame(minWidth: 700)
                        VStack(alignment: .leading, spacing: 28) {
                            GenreChart(genres: stats.topGenres)
                            ActorList(actors: stats.topActors)
                        }
                    }
                    Highlights(stats: stats)
                }

                if case let .year(year) = period, years.contains(where: { $0 != year }) {
                    CompareSection(year: year, years: years.filter { $0 != year }, comparedYear: $comparedYear,
                                   movies: movies, shows: shows)
                }

                if stats.undatedWatches > 0, period != .allTime {
                    Label("\(stats.undatedWatches) watched without a date \(stats.undatedWatches == 1 ? "is" : "are") only counted in All Time.",
                          systemImage: "calendar.badge.exclamationmark")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Stats")
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Period", selection: $period) {
                        ForEach(fixedPeriods, id: \.self) { Text($0.label).tag($0) }
                        Divider()
                        ForEach(yearPeriods(years), id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(period.label, systemImage: "calendar")
                        .labelStyle(.titleAndIcon)
                }
                .fixedSize()
            }
            if case .year = period, !stats.isEmpty {
                ToolbarItem {
                    Button("Year in Review", systemImage: "sparkles") { isShowingReview = true }
                }
            }
        }
        .sheet(isPresented: $isShowingReview) {
            if case let .year(year) = period {
                YearInReviewSheet(year: year, stats: stats)
            }
        }
    }

    private var fixedPeriods: [StatsPeriod] {
        [.thisWeek, .thisMonth, .lastDays(30), .lastDays(90), .allTime]
    }

    /// The current year is always offered, plus every year with watch history.
    private func yearPeriods(_ years: [Int]) -> [StatsPeriod] {
        let current = Calendar.current.component(.year, from: .now)
        return Set(years + [current]).sorted(by: >).map(StatsPeriod.year)
    }

    private var periodPhrase: String {
        switch period {
        case .allTime: "Yet"
        case let .year(year): "in \(year)"
        default: period.label
        }
    }
}

// MARK: - Summary

extension Int {
    /// Watch time: "3d 4h", "12h 30m", "45m".
    var watchTimeString: String {
        guard self > 0 else { return "0m" }
        return Duration.seconds(self * 60).formatted(
            .units(allowed: [.days, .hours, .minutes], width: .narrow, maximumUnitCount: 2)
        )
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let symbol: String
    var delta: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title, design: .rounded).weight(.bold))
                .monospacedDigit()
                .contentTransition(.numericText())
            if let delta {
                Text(delta).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

/// Four tiles in one row, or 2×2 when the row doesn't fit.
struct TileRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { content }
                .frame(minWidth: 620)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                content
            }
        }
    }
}

private struct SummaryTiles: View {
    let stats: WatchStats

    var body: some View {
        TileRow {
            StatTile(title: "Watch Time", value: stats.totalMinutes.watchTimeString, symbol: "clock")
            StatTile(title: "Movies", value: stats.moviesWatched.formatted(), symbol: "film")
            StatTile(title: "Episodes", value: stats.episodesWatched.formatted(), symbol: "tv")
            StatTile(title: "Shows", value: stats.showsWatched.formatted(), symbol: "rectangle.stack")
        }
    }
}

// MARK: - Activity

/// Watch time per day, month, or year. Single series in the accent color, so no legend;
/// hovering (or dragging on touch) reads out the bucket.
private struct ActivityChart: View {
    @Environment(\.themeColor) private var themeColor
    let stats: WatchStats
    @State private var selectedDate: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Activity").font(.title3.bold())
                Spacer()
                Text(readout).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            Chart {
                ForEach(stats.activity) { bucket in
                    BarMark(
                        x: .value("Period", bucket.start, unit: unit),
                        y: .value("Hours", Double(bucket.minutes) / 60)
                    )
                    .cornerRadius(4)
                    .foregroundStyle(isSelected(bucket) || selectedBucket == nil ? themeColor : themeColor.opacity(0.35))
                    .accessibilityLabel(label(for: bucket.start))
                    .accessibilityValue("\(bucket.minutes.watchTimeString), \(bucket.movies) movies, \(bucket.episodes) episodes")
                }
            }
            .chartXSelection(value: $selectedDate)
            .chartYAxisLabel("Hours")
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: stats.granularity == .month ? 12 : 8)) { _ in
                    AxisGridLine().foregroundStyle(.clear)
                    AxisValueLabel(format: axisFormat, centered: true)
                }
            }
            .frame(height: 200)
        }
    }

    private var unit: Calendar.Component {
        switch stats.granularity {
        case .day: .day
        case .month: .month
        case .year: .year
        }
    }

    private var axisFormat: Date.FormatStyle {
        switch stats.granularity {
        case .day: .dateTime.day()
        case .month: .dateTime.month(.narrow)
        case .year: .dateTime.year()
        }
    }

    private var selectedBucket: ActivityBucket? {
        guard let selectedDate else { return nil }
        return stats.activity.last { $0.start <= selectedDate }
    }

    private func isSelected(_ bucket: ActivityBucket) -> Bool { bucket.start == selectedBucket?.start }

    private func label(for date: Date) -> String {
        switch stats.granularity {
        case .day: date.formatted(date: .abbreviated, time: .omitted)
        case .month: date.formatted(.dateTime.month(.wide).year())
        case .year: date.formatted(.dateTime.year())
        }
    }

    private var readout: String {
        if let bucket = selectedBucket {
            var parts = ["\(label(for: bucket.start)): \(bucket.minutes.watchTimeString)"]
            if bucket.movies > 0 { parts.append("\(bucket.movies) movie\(bucket.movies == 1 ? "" : "s")") }
            if bucket.episodes > 0 { parts.append("\(bucket.episodes) episode\(bucket.episodes == 1 ? "" : "s")") }
            return parts.joined(separator: " · ")
        }
        let busiest = stats.activity.max { $0.minutes < $1.minutes }
        guard let busiest, busiest.minutes > 0 else { return "" }
        return "Busiest: \(label(for: busiest.start))"
    }
}

// MARK: - Genres and actors

private struct GenreChart: View {
    @Environment(\.themeColor) private var themeColor
    let genres: [RankedEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Top Genres").font(.title3.bold())
            if genres.isEmpty {
                Text("No genres yet.").foregroundStyle(.secondary)
            } else {
                let shown = Array(genres.prefix(8))
                Chart(shown) { genre in
                    BarMark(x: .value("Titles", genre.count), y: .value("Genre", genre.name))
                        .cornerRadius(4)
                        .foregroundStyle(themeColor)
                        .annotation(position: .trailing, spacing: 6) {
                            Text(genre.count.formatted()).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks { _ in AxisValueLabel().font(.callout) }
                }
                .frame(height: CGFloat(shown.count) * 30 + 10)
            }
        }
    }
}

private struct ActorList: View {
    let actors: [RankedEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Most Watched Actors").font(.title3.bold())
            if actors.isEmpty {
                Text("No cast information yet.").foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(actors.prefix(8).enumerated()), id: \.element.id) { index, actor in
                        HStack(spacing: 10) {
                            Text("\(index + 1)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 20)
                            AsyncImage(url: TMDBImage.url(actor.imagePath, size: .small)) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Image(systemName: "person.fill").foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary)
                            }
                            .frame(width: 34, height: 34)
                            .clipShape(.circle)
                            Text(actor.name)
                            Spacer()
                            Text("\(actor.count) title\(actor.count == 1 ? "" : "s")")
                                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
        }
    }
}

private struct Highlights: View {
    let stats: WatchStats

    var body: some View {
        if stats.mostWatchedShow != nil || stats.longestMovie != nil {
            VStack(alignment: .leading, spacing: 12) {
                Text("Highlights").font(.title3.bold())
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                    if let show = stats.mostWatchedShow {
                        highlight("Most Watched Show", entry: show, detail: "\(show.count) episode\(show.count == 1 ? "" : "s")")
                    }
                    if let movie = stats.longestMovie {
                        highlight("Longest Movie", entry: movie, detail: movie.count.watchTimeString)
                    }
                }
            }
        }
    }

    private func highlight(_ title: String, entry: RankedEntry, detail: String) -> some View {
        HStack(spacing: 12) {
            PosterImage(path: entry.imagePath, size: .small, cornerRadius: 6).frame(width: 50)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                Text(entry.name).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Comparison

/// Two years side by side as tiles with differences. Separate numbers, not a dual-axis chart:
/// counts and hours don't share a scale.
private struct CompareSection: View {
    let year: Int
    let years: [Int]
    @Binding var comparedYear: Int?
    let movies: [Movie]
    let shows: [TVShow]

    var body: some View {
        let other = comparedYear.flatMap { years.contains($0) ? $0 : nil } ?? years.first { $0 < year } ?? years[0]
        let current = StatsService.stats(movies: movies, shows: shows, period: .year(year))
        let previous = StatsService.stats(movies: movies, shows: shows, period: .year(other))

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Compared to").font(.title3.bold())
                Picker("Year", selection: Binding(get: { other }, set: { comparedYear = $0 })) {
                    ForEach(years, id: \.self) { Text(String($0)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            TileRow {
                StatTile(title: "Watch Time", value: current.totalMinutes.watchTimeString, symbol: "clock",
                         delta: delta(current.totalMinutes, previous.totalMinutes, other, format: \.watchTimeString))
                StatTile(title: "Movies", value: current.moviesWatched.formatted(), symbol: "film",
                         delta: delta(current.moviesWatched, previous.moviesWatched, other))
                StatTile(title: "Episodes", value: current.episodesWatched.formatted(), symbol: "tv",
                         delta: delta(current.episodesWatched, previous.episodesWatched, other))
                StatTile(title: "Shows", value: current.showsWatched.formatted(), symbol: "rectangle.stack",
                         delta: delta(current.showsWatched, previous.showsWatched, other))
            }
        }
    }

    private func delta(_ current: Int, _ previous: Int, _ year: Int, format: KeyPath<Int, String> = \.description) -> String {
        let difference = current - previous
        if difference == 0 { return "Same as \(year)" }
        let sign = difference > 0 ? "+" : "−"
        return "\(sign)\(abs(difference)[keyPath: format]) vs \(year) (\(previous[keyPath: format]))"
    }
}
