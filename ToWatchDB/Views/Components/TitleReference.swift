import CoreTransferable
import SwiftUI
import ToWatchCore
import UniformTypeIdentifiers

extension UTType {
    /// In-app drag type for titles; declared in Info.plist.
    static let towatchTitle = UTType(exportedAs: "com.mehdi.towatchdb.title")
}

/// A lightweight, value-type pointer to a movie or show: dragged between views and windows,
/// and used as the value that opens a title in its own window.
struct TitleReference: Codable, Hashable, Sendable, Transferable, Identifiable {
    let kind: MediaSummary.Kind
    let tmdbID: Int
    let title: String
    let posterPath: String?

    init(_ movie: Movie) {
        kind = .movie; tmdbID = movie.tmdbID; title = movie.title; posterPath = movie.posterPath
    }

    init(_ show: TVShow) {
        kind = .tv; tmdbID = show.tmdbID; title = show.name; posterPath = show.posterPath
    }

    init(_ summary: MediaSummary) {
        kind = summary.kind; tmdbID = summary.tmdbID; title = summary.title; posterPath = summary.posterPath
    }

    init(kind: MediaSummary.Kind, tmdbID: Int, title: String, posterPath: String?) {
        self.kind = kind; self.tmdbID = tmdbID; self.title = title; self.posterPath = posterPath
    }

    var id: String { "\(kind.rawValue)-\(tmdbID)" }

    var tmdbURL: URL { URL(string: "https://www.themoviedb.org/\(kind.rawValue)/\(tmdbID)")! }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .towatchTitle)
        // Other apps receive a TMDB link.
        ProxyRepresentation(exporting: \.tmdbURL)
    }
}

extension LibraryItem {
    var reference: TitleReference {
        switch self {
        case let .movie(movie): TitleReference(movie)
        case let .show(show): TitleReference(show)
        }
    }
}

extension LibraryService {
    /// Adds dropped titles to the library, optionally flagging them for the backlog.
    func add(_ references: [TitleReference], backlog: Bool) async throws {
        for reference in references {
            switch reference.kind {
            case .movie:
                let movie = try await addMovie(tmdbID: reference.tmdbID)
                if backlog { setBacklog(movie, true) }
            case .tv:
                let show = try await addShow(tmdbID: reference.tmdbID)
                if backlog { setBacklog(show, true) }
            }
        }
    }
}

// MARK: - Poster interactions shared by grids

extension View {
    /// Drag a title as a poster, and offer "Open in New Window" where the platform supports it.
    func titleInteractions(_ reference: TitleReference) -> some View {
        modifier(TitleInteractions(reference: reference))
    }
}

private struct TitleInteractions: ViewModifier {
    let reference: TitleReference
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .draggable(reference) {
                PosterImage(path: reference.posterPath, size: .small)
                    .frame(width: 90)
            }
            #if os(iOS)
            .hoverEffect(.lift)
            #else
            .scaleEffect(isHovering ? 1.03 : 1)
            .zIndex(isHovering ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: isHovering)
            .onHover { isHovering = $0 }
            #endif
    }
}

/// Context-menu item that opens a title in a separate window (iPad, Mac).
struct OpenInNewWindowButton: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    let reference: TitleReference

    var body: some View {
        if supportsMultipleWindows {
            Button("Open in New Window", systemImage: "macwindow.badge.plus") {
                openWindow(value: reference)
            }
        }
    }
}

/// Root of a secondary window showing one title.
struct TitleWindow: View {
    @Environment(AppState.self) private var appState
    let reference: TitleReference?

    var body: some View {
        NavigationStack {
            if let reference {
                RemoteDetailView(summary: MediaSummary(reference)).appDestinations()
            } else {
                ContentUnavailableView("No Title", systemImage: "film")
            }
        }
        .collectionEditorSheet(appState)
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 500)
        #endif
    }
}
