import Foundation

public enum TMDBError: LocalizedError, Sendable {
    case missingToken
    case http(status: Int, message: String?)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            "No TMDB access token. Add one in Settings."
        case let .http(status, message):
            message.map { "TMDB error \(status): \($0)" } ?? "TMDB error \(status)."
        case let .decoding(detail):
            "Unexpected response from TMDB. \(detail)"
        }
    }
}

/// Thin async client for the TMDB v3 API, authenticated with a v4 read access token.
public struct TMDBClient: Sendable {
    public static let baseURL = URL(string: "https://api.themoviedb.org/3/")!

    public let token: String
    public let language: String
    private let session: URLSession

    public init(token: String, language: String = TMDBClient.language(for: .current), session: URLSession = TMDBClient.session) {
        self.token = token
        self.language = language
        self.session = session
    }

    /// A stalled connection otherwise kept a refresh (four titles at a time) spinning for URLSession's default
    /// minute per request. Images keep the shared session and its cache.
    ///
    /// Responses get a cache of their own. TMDB answers `max-age=0` with an ETag, so a cached one is only ever
    /// checked again (an unchanged show comes back as a short 304); in the shared cache, sized for posters, a show
    /// with its seasons appended (hundreds of KB, a few MB for a long-running one) pushed posters out.
    public static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.urlCache = URLCache(memoryCapacity: 4 << 20, diskCapacity: 128 << 20,
                                          directory: URL.cachesDirectory.appending(path: "TMDB Responses"))
        return URLSession(configuration: configuration)
    }()

    /// TMDB's `language` for a locale: "fr-CA", or just "fr". A full BCP 47 tag can carry extensions
    /// ("en-US-u-ca-buddhist") or a numeric region ("es-419") that TMDB doesn't take.
    public static func language(for locale: Locale) -> String {
        let language = locale.language.languageCode?.identifier ?? "en"
        guard let region = locale.region?.identifier, region.count == 2, region.allSatisfy(\.isLetter) else { return language }
        return "\(language)-\(region)"
    }

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    // MARK: Endpoints

    /// `year` matches any of a movie's release dates (theatrical, regional, re-release), not just the first.
    public func searchMovies(_ query: String, year: Int? = nil, page: Int = 1) async throws -> TMDBPage<TMDBMovieSummary> {
        var parameters = ["query": query, "page": String(page), "include_adult": "false"]
        if let year { parameters["year"] = String(year) }
        return try await get("search/movie", parameters)
    }

    public func searchTVShows(_ query: String, year: Int? = nil, page: Int = 1) async throws -> TMDBPage<TMDBTVSummary> {
        var parameters = ["query": query, "page": String(page), "include_adult": "false"]
        if let year { parameters["first_air_date_year"] = String(year) }
        return try await get("search/tv", parameters)
    }

    public func trendingMovies() async throws -> TMDBPage<TMDBMovieSummary> {
        try await get("trending/movie/week")
    }

    public func trendingTVShows() async throws -> TMDBPage<TMDBTVSummary> {
        try await get("trending/tv/week")
    }

    public func movie(id: Int) async throws -> TMDBMovieDetail {
        try await get("movie/\(id)", ["append_to_response": "credits,videos", "include_video_language": videoLanguages])
    }

    public func tvShow(id: Int) async throws -> TMDBTVDetail {
        try await get("tv/\(id)", tvShowQuery())
    }

    private func tvShowQuery(appending extra: [String] = []) -> [String: String] {
        ["append_to_response": (["credits", "videos", "external_ids"] + extra).joined(separator: ","),
         "include_video_language": videoLanguages]
    }

    /// A show's IDs on other sites, such as IMDb.
    public func tvExternalIDs(id: Int) async throws -> TMDBExternalIDs {
        try await get("tv/\(id)/external_ids")
    }

    /// Videos are filtered by `language`, and most trailers exist only in English: without a fallback,
    /// a French or German user would get no trailer at all. Order doesn't matter to TMDB; ranking does that.
    var videoLanguages: String {
        let primary = language.split(separator: "-").first.map(String.init) ?? "en"
        return primary == "en" ? "en,null" : "\(primary),en,null"
    }

    public func season(showID: Int, seasonNumber: Int) async throws -> TMDBSeasonDetail {
        try await get("tv/\(showID)/season/\(seasonNumber)")
    }

    /// Show detail plus every season's episode list. Seasons 0–16 come in the detail request itself (TMDB takes
    /// 20 appended items and leaves out seasons that don't exist): a request per season made refreshing a
    /// library hundreds of requests, enough to hit TMDB's rate limit. Any other season is fetched on its own.
    public func tvShowWithSeasons(id: Int) async throws -> (TMDBTVDetail, [TMDBSeasonDetail]) {
        let data = try await data("tv/\(id)", tvShowQuery(appending: (0..<17).map { "season/\($0)" }))
        let detail: TMDBTVDetail = try Self.decode(data)
        let appended = (try? Self.decoder.decode(AppendedSeasons.self, from: data))?.seasons ?? []
        let have = Set(appended.map(\.seasonNumber))
        let missing = (detail.seasons ?? []).map(\.seasonNumber).filter { !have.contains($0) }
        let seasons = appended + (try await seasons(numbered: missing, showID: id))
        return (detail, seasons.sorted { $0.seasonNumber < $1.seasonNumber })
    }

    /// The `season/N` entries of a show detail with seasons appended.
    struct AppendedSeasons: Decodable {
        let seasons: [TMDBSeasonDetail]

        private struct Key: CodingKey {
            let stringValue: String
            init(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { nil }
            init?(intValue: Int) { nil }
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            seasons = container.allKeys.filter { $0.stringValue.hasPrefix("season/") }
                .compactMap { try? container.decode(TMDBSeasonDetail.self, forKey: $0) }
        }
    }

    /// Every season's episode list for an already-fetched show, fetched concurrently.
    public func seasons(of detail: TMDBTVDetail) async throws -> [TMDBSeasonDetail] {
        try await seasons(numbered: (detail.seasons ?? []).map(\.seasonNumber), showID: detail.id)
    }

    private func seasons(numbered numbers: [Int], showID id: Int) async throws -> [TMDBSeasonDetail] {
        // At most 6 at a time: a long-running show has dozens of seasons, and a burst of requests that size
        // (times the titles refreshed together) can hit TMDB's rate limit, which fails the whole show.
        let seasons = try await withThrowingTaskGroup(of: TMDBSeasonDetail.self) { group in
            var pending = numbers.makeIterator()
            var seasons: [TMDBSeasonDetail] = []
            for _ in 0..<6 {
                guard let number = pending.next() else { break }
                group.addTask { try await self.season(showID: id, seasonNumber: number) }
            }
            while let season = try await group.next() {
                seasons.append(season)
                if let number = pending.next() {
                    group.addTask { try await self.season(showID: id, seasonNumber: number) }
                }
            }
            return seasons
        }
        return seasons.sorted { $0.seasonNumber < $1.seasonNumber }
    }

    // MARK: Transport

    func get<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> T {
        try Self.decode(try await data(path, query))
    }

    static func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw TMDBError.decoding(String(describing: error))
        }
    }

    func data(_ path: String, _ query: [String: String] = [:]) async throws -> Data {
        guard !token.isEmpty else { throw TMDBError.missingToken }

        var components = URLComponents(url: Self.baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = (query.merging(["language": language]) { current, _ in current })
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        // URLComponents leaves "+" as is, and servers read it as a space: "C++" searched for "C  ".
        components.percentEncodedQuery = components.percentEncodedQuery?.replacing("+", with: "%2B")

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var (data, response) = try await session.data(for: request)
        // Rate limited: wait as asked (briefly) and try once more, rather than failing a whole refresh or import.
        if let http = response as? HTTPURLResponse, http.statusCode == 429 {
            let wait = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 1
            try await Task.sleep(for: .seconds(min(max(wait, 0.5), 10)))
            (data, response) = try await session.data(for: request)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = try? Self.decoder.decode(TMDBErrorBody.self, from: data)
            throw TMDBError.http(status: status, message: body?.statusMessage)
        }
        return data
    }
}

public enum TMDBImageSize: String, Sendable {
    case small = "w185"
    case poster = "w342"
    case backdrop = "w1280"
    case still = "w300"
    case logo = "w92"
}

public enum TMDBImage {
    public static func url(_ path: String?, size: TMDBImageSize) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/\(size.rawValue)\(path)")
    }
}
