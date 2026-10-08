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

/// Reads IMDb ratings from OMDb (omdbapi.com) with the user's own API key. A free key allows 1,000 lookups a
/// day, one title per lookup. Ratings are a nicety, so callers treat every failure as "no rating" rather than
/// an error to show.
public struct IMDbClient: Sendable {
    public static let endpoint = URL(string: "https://www.omdbapi.com/")!
    /// Lookups running at once.
    static let concurrency = 4

    private let apiKey: String
    private let session: URLSession

    public init(apiKey: String, session: URLSession = IMDbClient.session) {
        self.apiKey = apiKey
        self.session = session
    }

    /// Ratings are a nicety, so a request gives up after 10 seconds rather than URLSession's default minute.
    public static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }()

    /// OMDb turned the key down: it's wrong, or it used up its daily lookups.
    public struct Rejected: LocalizedError {
        public let message: String
        public var errorDescription: String? { "OMDb: \(message)" }
    }

    /// Ratings keyed by IMDb ID (`tt…`). A `nil` value means OMDb answered for that title but has no rating
    /// (or doesn't know the ID); IDs it didn't answer for are left out, so their stored ratings stay as they are.
    /// A failed lookup only leaves its title out. When OMDb rejects the key (or its daily limit is reached), the
    /// remaining lookups are skipped. Throws only if no title was answered.
    public func ratings(for ids: [String]) async throws -> [String: IMDbRating?] {
        // IDs go in the URL, so anything that isn't a plain `tt` ID is dropped.
        var pending = Array(Set(ids.filter(Self.isValidID))).sorted()[...]
        var ratings: [String: IMDbRating?] = [:]
        var lastError: (any Error)?
        var answered = false
        try await withThrowingTaskGroup(of: (String, Result<IMDbRating?, any Error>).self) { group in
            func startNext() {
                guard let id = pending.popFirst() else { return }
                group.addTask {
                    do { return (id, .success(try await fetch(id))) } catch { return (id, .failure(error)) }
                }
            }
            for _ in 0..<Self.concurrency { startNext() }
            while let (id, result) = try await group.next() {
                switch result {
                case let .success(rating):
                    ratings.updateValue(rating, forKey: id)
                    answered = true
                    startNext()
                case .failure(is CancellationError):
                    throw CancellationError()
                case let .failure(error as Rejected):
                    // Every other lookup would be turned down too.
                    lastError = error
                    pending = []
                case let .failure(error):
                    lastError = error
                    startNext()
                }
            }
        }
        if !answered, let lastError { throw lastError }
        return ratings
    }

    static func isValidID(_ id: String) -> Bool {
        id.count > 2 && id.hasPrefix("tt") && id.dropFirst(2).allSatisfy(\.isASCII) && id.dropFirst(2).allSatisfy(\.isNumber)
    }

    private func fetch(_ id: String) async throws -> IMDbRating? {
        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "apikey", value: apiKey), URLQueryItem(name: "i", value: id)]
        let (data, response) = try await session.data(from: components.url!)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // A wrong key or a used-up daily limit answers 401, with the reason in the body.
        if status == 401 {
            throw Rejected(message: (try? JSONDecoder().decode(Response.self, from: data))?.error ?? "Invalid API key!")
        }
        guard (200..<300).contains(status) else { throw URLError(.badServerResponse) }
        return try Self.decode(data)
    }

    /// The rating in one OMDb answer: `nil` when the title has none or OMDb doesn't know the ID.
    /// Throws for any other error, so the title's stored rating is kept.
    static func decode(_ data: Data) throws -> IMDbRating? {
        let body = try JSONDecoder().decode(Response.self, from: data)
        guard body.response == "True" else {
            let message = body.error ?? ""
            if message.localizedCaseInsensitiveContains("not found") || message.localizedCaseInsensitiveContains("incorrect imdb id") {
                return nil
            }
            if message.localizedCaseInsensitiveContains("api key") || message.localizedCaseInsensitiveContains("limit") {
                throw Rejected(message: message)
            }
            throw URLError(.cannotParseResponse)
        }
        guard let value = body.imdbRating.flatMap(Double.init), value > 0 else { return nil }
        let votes = body.imdbVotes.flatMap { Int($0.filter(\.isNumber)) } ?? 0
        return IMDbRating(value: value, votes: votes)
    }

    private struct Response: Decodable {
        let response: String
        let error: String?
        let imdbRating: String?
        let imdbVotes: String?

        private enum CodingKeys: String, CodingKey {
            case response = "Response", error = "Error", imdbRating, imdbVotes
        }
    }
}
