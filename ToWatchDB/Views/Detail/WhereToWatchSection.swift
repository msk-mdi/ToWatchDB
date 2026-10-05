import SwiftUI
import ToWatchCore

/// Streaming, free, ad-supported, rent, and buy options for a title in one country.
/// Data comes from TMDB via JustWatch, which must be credited; provider links go through TMDB's watch page.
struct WhereToWatchSection: View {
    @Environment(AppState.self) private var appState
    let kind: MediaSummary.Kind
    let tmdbID: Int

    @State private var providers: TMDBWatchProviders?
    @State private var failed = false

    var body: some View {
        @Bindable var appState = appState
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Where to Watch").font(.title3.bold())
                Spacer()
                if let providers, !providers.results.isEmpty {
                    Picker("Country", selection: $appState.watchRegion) {
                        ForEach(countries(providers), id: \.self) { code in
                            Text(countryName(code)).tag(code)
                        }
                    }
                    .fixedSize()
                }
            }

            if let providers {
                if let offers = providers.results[appState.watchRegion], !offers.sections.isEmpty {
                    ForEach(offers.sections) { section in
                        ProviderRow(section: section, link: offers.link.flatMap(URL.init(string:)))
                    }
                } else {
                    Text("Not available to stream, rent, or buy in \(countryName(appState.watchRegion)).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text("Availability powered by JustWatch.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if failed {
                Text("Couldn't load streaming availability.").font(.callout).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .task(id: tmdbID) { await load() }
    }

    /// The chosen country stays in the picker even when this title has no offers there.
    private func countries(_ providers: TMDBWatchProviders) -> [String] {
        var codes = providers.countries()
        if !codes.contains(appState.watchRegion) { codes.insert(appState.watchRegion, at: 0) }
        return codes
    }

    private func countryName(_ code: String) -> String {
        Locale.current.localizedString(forRegionCode: code) ?? code
    }

    private func load() async {
        // Start clean: this view can be reused for another title, and a missing token shouldn't spin forever.
        providers = nil
        failed = false
        guard let client = appState.client else {
            failed = true
            return
        }
        do {
            providers = switch kind {
            case .movie: try await client.watchProviders(movieID: tmdbID)
            case .tv: try await client.watchProviders(showID: tmdbID)
            }
        } catch is CancellationError {
        } catch {
            failed = true
        }
    }
}

private struct ProviderRow: View {
    let section: TMDBCountryProviders.Section
    let link: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(section.kind.label).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(section.providers) { provider in
                        providerTile(provider)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private func providerTile(_ provider: TMDBProvider) -> some View {
        let tile = VStack(spacing: 4) {
            AsyncImage(url: TMDBImage.url(provider.logoPath, size: .logo)) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary)
            }
            .frame(width: 48, height: 48)
            .clipShape(.rect(cornerRadius: 10))
            Text(provider.providerName)
                .font(.caption2)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 64)
        }
        .accessibilityElement(children: .combine)

        if let link {
            Link(destination: link) { tile }
                .buttonStyle(.plain)
                .help("Open on TMDB to watch with \(provider.providerName)")
        } else {
            tile
        }
    }
}
