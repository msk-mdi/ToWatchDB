import Foundation

// Where to watch, from TMDB's /watch/providers (data supplied by JustWatch, which must be credited).

public struct TMDBProvider: Codable, Sendable, Hashable, Identifiable {
    public let providerId: Int
    public let providerName: String
    public let logoPath: String?
    public let displayPriority: Int?

    public var id: Int { providerId }
}

public struct TMDBCountryProviders: Codable, Sendable, Hashable {
    /// TMDB's watch page for this title and country; links out to each service.
    public let link: String?
    public let flatrate: [TMDBProvider]?
    public let free: [TMDBProvider]?
    public let ads: [TMDBProvider]?
    public let rent: [TMDBProvider]?
    public let buy: [TMDBProvider]?

    public enum Kind: String, Sendable, CaseIterable, Identifiable {
        case stream, free, ads, rent, buy
        public var id: Self { self }
        public var label: String {
            switch self {
            case .stream: "Stream"
            case .free: "Free"
            case .ads: "With Ads"
            case .rent: "Rent"
            case .buy: "Buy"
            }
        }
    }

    public struct Section: Sendable, Hashable, Identifiable {
        public let kind: Kind
        public let providers: [TMDBProvider]
        public var id: Kind { kind }
    }

    /// Non-empty offer types in a fixed order, each sorted by TMDB's display priority.
    public var sections: [Section] {
        let all: [(Kind, [TMDBProvider]?)] = [(.stream, flatrate), (.free, free), (.ads, ads), (.rent, rent), (.buy, buy)]
        return all.compactMap { kind, providers in
            guard let providers, !providers.isEmpty else { return nil }
            let sorted = providers.sorted { ($0.displayPriority ?? .max, $0.providerName) < ($1.displayPriority ?? .max, $1.providerName) }
            return Section(kind: kind, providers: sorted)
        }
    }
}

public struct TMDBWatchProviders: Codable, Sendable, Hashable {
    public let id: Int
    /// Keyed by ISO 3166-1 country code, e.g. "FR".
    public let results: [String: TMDBCountryProviders]

    /// Country codes with any offer, sorted by their name in the given locale.
    public func countries(locale: Locale = .current) -> [String] {
        // Each name looked up once, not twice per comparison.
        results.keys
            .map { (code: $0, name: locale.localizedString(forRegionCode: $0) ?? $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map(\.code)
    }
}

public extension TMDBClient {
    func watchProviders(movieID: Int) async throws -> TMDBWatchProviders {
        try await get("movie/\(movieID)/watch/providers")
    }

    func watchProviders(showID: Int) async throws -> TMDBWatchProviders {
        try await get("tv/\(showID)/watch/providers")
    }
}
