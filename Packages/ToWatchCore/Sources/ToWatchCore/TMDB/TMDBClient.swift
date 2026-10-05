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

    public init(token: String, language: String = Locale.current.identifier(.bcp47), session: URLSession = .shared) {
        self.token = token
        self.language = language
        self.session = session
    }

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    // MARK: Endpoints

    public func searchMovies(_ query: String, page: Int = 1) async throws -> TMDBPage<TMDBMovieSummary> {
        try await get("search/movie", ["query": query, "page": String(page), "include_adult": "false"])
    }

    public func searchTVShows(_ query: String, page: Int = 1) async throws -> TMDBPage<TMDBTVSummary> {
        try await get("search/tv", ["query": query, "page": String(page), "include_adult": "false"])
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
        try await get("tv/\(id)", ["append_to_response": "credits,videos", "include_video_language": videoLanguages])
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

    /// Show detail plus every season's episode list, fetched concurrently.
    public func tvShowWithSeasons(id: Int) async throws -> (TMDBTVDetail, [TMDBSeasonDetail]) {
        let detail = try await tvShow(id: id)
        let numbers = (detail.seasons ?? []).map(\.seasonNumber)
        let seasons = try await withThrowingTaskGroup(of: TMDBSeasonDetail.self) { group in
            for number in numbers {
                group.addTask { try await self.season(showID: id, seasonNumber: number) }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        return (detail, seasons.sorted { $0.seasonNumber < $1.seasonNumber })
    }

    // MARK: Transport

    func get<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> T {
        guard !token.isEmpty else { throw TMDBError.missingToken }

        var components = URLComponents(url: Self.baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = (query.merging(["language": language]) { current, _ in current })
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = try? Self.decoder.decode(TMDBErrorBody.self, from: data)
            throw TMDBError.http(status: status, message: body?.statusMessage)
        }
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw TMDBError.decoding(String(describing: error))
        }
    }
}

public enum TMDBImageSize: String, Sendable {
    case small = "w185"
    case poster = "w342"
    case posterLarge = "w500"
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
