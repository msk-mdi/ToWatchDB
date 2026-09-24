import SwiftUI
import ToWatchCore

/// Common detail page: backdrop, poster + title header, actions, overview, facts, extra content, and cast.
struct DetailLayout<Actions: View, Extra: View>: View {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isCompact: Bool { sizeClass == .compact }
    #else
    private let isCompact = false
    #endif

    let title: String
    let subtitle: String
    let posterPath: String?
    let backdropPath: String?
    var tagline: String?
    var overview: String?
    var genres: [String] = []
    var facts: [(String, String)] = []
    var cast: [PersonCredit] = []
    @ViewBuilder var actions: Actions
    @ViewBuilder var extra: Extra

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                BackdropImage(path: backdropPath, height: isCompact ? 220 : 320)

                HStack(alignment: .bottom, spacing: isCompact ? 14 : 20) {
                    PosterImage(path: posterPath, size: .posterLarge, cornerRadius: 10)
                        .frame(width: isCompact ? 110 : 170)
                        .shadow(radius: 12, y: 6)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title)
                            .font(isCompact ? .title2.bold() : .largeTitle.bold())
                            .textSelection(.enabled)
                        Text(subtitle)
                            .foregroundStyle(.secondary)
                        if !genres.isEmpty {
                            ViewThatFits(in: .horizontal) {
                                HStack { ForEach(genres, id: \.self) { Chip(text: $0) } }
                                HStack { ForEach(genres.prefix(2), id: \.self) { Chip(text: $0) } }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, isCompact ? -90 : -150)

                VStack(alignment: .leading, spacing: 24) {
                    actions

                    if tagline != nil || overview != nil {
                        VStack(alignment: .leading, spacing: 8) {
                            if let tagline {
                                Text(tagline).font(.headline).italic().foregroundStyle(.secondary)
                            }
                            if let overview, !overview.isEmpty {
                                Text(overview)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: 760, alignment: .leading)
                            }
                        }
                    }

                    if !facts.isEmpty {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                            ForEach(facts, id: \.0) { label, value in
                                GridRow {
                                    Text(label).foregroundStyle(.secondary)
                                    Text(value).textSelection(.enabled)
                                }
                            }
                        }
                        .font(.callout)
                    }

                    extra

                    if !cast.isEmpty {
                        CastRow(cast: cast)
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, 32)
            }
        }
        .ignoresSafeArea(edges: .top)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var horizontalPadding: CGFloat { isCompact ? 16 : 24 }
}

/// A row of detail actions: scrolls sideways on iPhone instead of overflowing.
struct ActionBar<Content: View>: View {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @ViewBuilder let content: Content

    var body: some View {
        #if os(iOS)
        if sizeClass == .compact {
            ScrollView(.horizontal) {
                HStack(spacing: 10) { content }.padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            .buttonStyle(.bordered)
        } else {
            HStack(spacing: 12) { content }.buttonStyle(.bordered)
        }
        #else
        HStack(spacing: 12) { content }
        #endif
    }
}

struct CastRow: View {
    let cast: [PersonCredit]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cast").font(.title3.bold())
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(cast) { person in
                        VStack(spacing: 6) {
                            AsyncImage(url: TMDBImage.url(person.profilePath, size: .small)) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Image(systemName: "person.fill")
                                    .font(.title2)
                                    .foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background(.quaternary)
                            }
                            .frame(width: 72, height: 72)
                            .clipShape(.circle)
                            Text(person.name)
                                .font(.caption.weight(.medium))
                                .lineLimit(2)
                            if let role = person.role, !role.isEmpty {
                                Text(role)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .multilineTextAlignment(.center)
                        .frame(width: 96)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}

/// Shared "Trailer" / "TMDB" / "IMDb" links.
struct ExternalLinks: View {
    let kind: MediaSummary.Kind
    let tmdbID: Int
    var trailerKey: String?
    var imdbID: String?
    var homepage: String?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { links }
            VStack(alignment: .leading, spacing: 8) { links }
        }
        .font(.callout)
    }

    @ViewBuilder
    private var links: some View {
        Group {
            if let trailerKey, let url = URL(string: "https://www.youtube.com/watch?v=\(trailerKey)") {
                Link(destination: url) { Label("Trailer", systemImage: "play.rectangle") }
            }
            if let url = URL(string: "https://www.themoviedb.org/\(kind.rawValue)/\(tmdbID)") {
                Link(destination: url) { Label("TMDB", systemImage: "link") }
            }
            if let imdbID, let url = URL(string: "https://www.imdb.com/title/\(imdbID)") {
                Link(destination: url) { Label("IMDb", systemImage: "link") }
            }
            if let homepage, let url = URL(string: homepage) {
                Link(destination: url) { Label("Website", systemImage: "globe") }
            }
        }
    }
}
