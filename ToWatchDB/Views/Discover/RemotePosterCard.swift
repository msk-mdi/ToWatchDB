import SwiftUI
import ToWatchCore

/// Poster card for a TMDB result, with a quick "add to library" button.
struct RemotePosterCard: View {
    @Environment(AppState.self) private var appState
    let summary: MediaSummary
    let isInLibrary: Bool
    @State private var isAdding = false

    var body: some View {
        NavigationLink(value: summary) {
            VStack(alignment: .leading, spacing: 6) {
                PosterImage(path: summary.posterPath)
                    .overlay(alignment: .topTrailing) { badge.padding(6) }
                Text(summary.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2, reservesSpace: true)
                Text(summary.date?.yearString ?? "—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .titleInteractions(TitleReference(summary))
        .contextMenu {
            if !isInLibrary {
                Button("Add to Library", systemImage: "plus") { add(backlog: false) }
                Button("Add to Backlog", systemImage: "tray.and.arrow.down") { add(backlog: true) }
            }
            OpenInNewWindowButton(reference: TitleReference(summary))
        }
    }

    @ViewBuilder
    private var badge: some View {
        if isInLibrary {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .green)
                .shadow(radius: 2)
                .accessibilityLabel("In library")
        } else if isAdding {
            ProgressView().controlSize(.small)
                .padding(4)
                .background(.thinMaterial, in: .circle)
        } else {
            Button { add(backlog: false) } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .shadow(radius: 2)
            }
            .buttonStyle(.plain)
            .help("Add to Library")
            .accessibilityLabel("Add \(summary.title) to library")
        }
    }

    private func add(backlog: Bool) {
        isAdding = true
        Task {
            await appState.perform { library in
                switch summary.kind {
                case .movie:
                    let movie = try await library.addMovie(tmdbID: summary.tmdbID)
                    if backlog { library.setBacklog(movie, true) }
                case .tv:
                    let show = try await library.addShow(tmdbID: summary.tmdbID)
                    if backlog { library.setBacklog(show, true) }
                }
            }
            isAdding = false
        }
    }
}

/// Adaptive poster grid used by search, discover, and library views.
struct PosterGrid<Content: View>: View {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @ViewBuilder let content: Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumWidth, maximum: 200), spacing: 12, alignment: .top)], spacing: 20) {
            content
        }
    }

    /// Three columns on iPhone, larger posters with more room elsewhere.
    private var minimumWidth: CGFloat {
        #if os(iOS)
        sizeClass == .compact ? 100 : 140
        #else
        140
        #endif
    }
}
