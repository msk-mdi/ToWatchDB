import ImageIO
import SwiftUI
import ToWatchCore

/// Shareable Year in Review card: rendered to an image with the posters pre-downloaded,
/// because `ImageRenderer` can't wait for `AsyncImage`.
struct YearInReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let year: Int
    let stats: WatchStats

    @State private var posters: [CGImage] = []
    @State private var rendered: Image?

    var body: some View {
        NavigationStack {
            ScrollView {
                YearInReviewCard(year: year, stats: stats, posters: posters)
                    .clipShape(.rect(cornerRadius: 20))
                    .shadow(radius: 12, y: 6)
                    .padding()
            }
            .navigationTitle("\(String(year)) in Review")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if let rendered {
                        ShareLink(item: rendered, preview: SharePreview("My \(String(year)) in Review", image: rendered))
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 640)
        #endif
        .task {
            posters = await PosterLoader.load(stats.posterPaths.prefix(6))
            rendered = render()
        }
    }

    @MainActor
    private func render() -> Image? {
        let renderer = ImageRenderer(content: YearInReviewCard(year: year, stats: stats, posters: posters))
        renderer.scale = 3
        guard let cgImage = renderer.cgImage else { return nil }
        return Image(decorative: cgImage, scale: 1)
    }
}

/// A 4:5 card sized for social sharing (1080×1350 at 3×).
struct YearInReviewCard: View {
    let year: Int
    let stats: WatchStats
    let posters: [CGImage]

    private let ink = Color.white

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("MY YEAR IN MOVIES & TV").font(.caption.weight(.heavy)).tracking(1.5).opacity(0.8)
                Text(String(year)).font(.system(size: 56, weight: .black, design: .rounded))
            }

            if !posters.isEmpty {
                // Fixed height: however many posters there are, the card's layout doesn't move.
                HStack(spacing: 6) {
                    ForEach(Array(posters.enumerated()), id: \.offset) { _, poster in
                        Image(decorative: poster, scale: 1)
                            .resizable()
                            .aspectRatio(2 / 3, contentMode: .fit)
                            .clipShape(.rect(cornerRadius: 6))
                    }
                }
                .frame(height: 100, alignment: .leading)
            }

            HStack(alignment: .top, spacing: 12) {
                figure(stats.totalMinutes.watchTimeString, "watched")
                figure(stats.moviesWatched.formatted(), stats.moviesWatched == 1 ? "movie" : "movies")
                figure(stats.episodesWatched.formatted(), stats.episodesWatched == 1 ? "episode" : "episodes")
            }

            VStack(alignment: .leading, spacing: 10) {
                if let genre = stats.topGenres.first { fact("Top genre", genre.name) }
                if let actor = stats.topActors.first { fact("Most watched actor", actor.name) }
                if let show = stats.mostWatchedShow { fact("Most watched show", "\(show.name) · \(show.count) episodes") }
            }

        }
        .foregroundStyle(ink)
        .padding(28)
        .frame(width: 360, height: 450, alignment: .topLeading)
        .overlay(alignment: .bottomTrailing) {
            Text("ToWatchDB").font(.caption.weight(.semibold)).foregroundStyle(ink.opacity(0.7)).padding(20)
        }
        .background(
            LinearGradient(colors: [Color(red: 0.18, green: 0.13, blue: 0.42), Color(red: 0.93, green: 0.36, blue: 0.36)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(.title2, design: .rounded).weight(.bold)).minimumScaleFactor(0.6).lineLimit(1)
            Text(label).font(.caption).opacity(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased()).font(.caption2.weight(.bold)).tracking(1).opacity(0.7)
            Text(value).font(.headline).lineLimit(1)
        }
    }
}

enum PosterLoader {
    /// Downloads posters in order, skipping any that fail. Goes through `ImageCache`, so posters already shown
    /// in the library are used as they are.
    static func load(_ paths: some Sequence<String>) async -> [CGImage] {
        let urls = paths.compactMap { TMDBImage.url($0, size: .poster) }
        return await withTaskGroup(of: (Int, CGImage?).self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask { (index, try? await ImageCache.shared.load(url).image) }
            }
            var images: [(Int, CGImage)] = []
            for await (index, image) in group {
                if let image { images.append((index, image)) }
            }
            return images.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}
