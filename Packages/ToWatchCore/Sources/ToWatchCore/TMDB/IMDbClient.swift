import Foundation

/// A title's IMDb user rating: the 1–10 average and how many votes it's based on.
public struct IMDbRating: Sendable, Hashable {
    public let value: Double
    public let votes: Int

    public init(value: Double, votes: Int) {
        self.value = value
        self.votes = votes
    }
}

/// Reads IMDb ratings from the GraphQL endpoint imdb.com itself uses. It needs no key but isn't a documented
/// API, so callers treat every failure as "no rating" rather than an error to show. IMDb allows only limited,
/// personal, non-commercial use of this data.
public struct IMDbClient: Sendable {
    public static let endpoint = URL(string: "https://api.graphql.imdb.com/")!
    /// Titles asked for in one request (each is an aliased field of the same query).
    static let batchSize = 50

    private let session: URLSession

    public init(session: URLSession = IMDbClient.session) {
        self.session = session
    }

    /// Ratings are a nicety, so a request gives up after 10 seconds rather than URLSession's default minute.
    public static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }()

    /// Ratings keyed by IMDb ID (`tt…`). A `nil` value means IMDb answered for that title but has no rating
    /// (or doesn't know the ID); IDs it didn't answer for are left out, so their stored ratings stay as they are.
    /// Throws when IMDb returns no data, which it does with a 200 status when it rejects or limits a query.
    /// A failed batch only leaves its titles out, so a limit hit late in a big library keeps the earlier ones;
    /// it throws only if every batch failed.
    public func ratings(for ids: [String]) async throws -> [String: IMDbRating?] {
        // IDs are interpolated into the query, so anything that isn't a plain `tt` ID is dropped.
        let valid = Array(Set(ids.filter(Self.isValidID))).sorted()
        var ratings: [String: IMDbRating?] = [:]
        var lastError: (any Error)?
        var answered = false
        for start in stride(from: 0, to: valid.count, by: Self.batchSize) {
            let batch = Array(valid[start..<min(start + Self.batchSize, valid.count)])
            do {
                try await ratings.merge(fetch(batch)) { _, new in new }
                answered = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        if !answered, let lastError { throw lastError }
        return ratings
    }

    static func isValidID(_ id: String) -> Bool {
        id.count > 2 && id.hasPrefix("tt") && id.dropFirst(2).allSatisfy(\.isASCII) && id.dropFirst(2).allSatisfy(\.isNumber)
    }

    static func query(for ids: [String]) -> String {
        let fields = ids.enumerated().map { index, id in
            "t\(index): title(id: \"\(id)\") { ratingsSummary { aggregateRating voteCount } }"
        }
        return "{ \(fields.joined(separator: " ")) }"
    }

    private func fetch(_ ids: [String]) async throws -> [String: IMDbRating?] {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Without a client name the endpoint answers 403.
        request.setValue("imdb-web-next-localized", forHTTPHeaderField: "x-imdb-client-name")
        request.httpBody = try JSONEncoder().encode(["query": Self.query(for: ids)])

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw URLError(.badServerResponse) }
        return try Self.decode(data, ids: ids)
    }

    static func decode(_ data: Data, ids: [String]) throws -> [String: IMDbRating?] {
        let body = try JSONDecoder().decode(Response.self, from: data)
        let errors = body.errors ?? []
        // GraphQL reports failures in `errors` with a 200 status. Without data, or with an error that isn't tied
        // to one title, nothing in the response can be trusted: reading it as "no ratings" cleared every rating.
        guard let titles = body.data, errors.allSatisfy({ $0.alias != nil }) else {
            throw URLError(.cannotParseResponse)
        }
        let failed = Set(errors.compactMap(\.alias))
        var ratings: [String: IMDbRating?] = [:]
        for (index, id) in ids.enumerated() {
            let alias = "t\(index)"
            // A title whose field failed comes back null like an unknown one; leave it out so it's kept.
            guard !failed.contains(alias), let title = titles[alias] else { continue }
            if let summary = title?.ratingsSummary, let value = summary.aggregateRating, value > 0 {
                ratings[id] = IMDbRating(value: value, votes: summary.voteCount ?? 0)
            } else {
                ratings.updateValue(nil, forKey: id)
            }
        }
        return ratings
    }

    private struct Response: Decodable {
        let data: [String: Title?]?
        let errors: [GraphQLError]?
    }

    private struct GraphQLError: Decodable {
        /// The query alias (`t0`, `t1`…) the error belongs to, from the first element of its `path`.
        let alias: String?

        private enum CodingKeys: String, CodingKey { case path }
        private enum PathElement: Decodable {
            case key(String), index(Int)
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let key = try? container.decode(String.self) { self = .key(key) } else { self = .index(try container.decode(Int.self)) }
            }
        }

        init(from decoder: Decoder) throws {
            let path = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent([PathElement].self, forKey: .path)
            if case let .key(alias)? = path?.first { self.alias = alias } else { alias = nil }
        }
    }

    private struct Title: Decodable {
        let ratingsSummary: Summary?
    }

    private struct Summary: Decodable {
        let aggregateRating: Double?
        let voteCount: Int?
    }
}
