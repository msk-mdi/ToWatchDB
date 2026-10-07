import Foundation

public enum SeerrError: LocalizedError, Sendable {
    case invalidServer
    case unauthorized
    case signInFailed(String?)
    case noSession
    case http(status: Int, message: String?)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .invalidServer:
            "The Seerr server address isn't a valid URL."
        case .unauthorized:
            "Seerr didn't accept the sign-in, or it expired. Sign in again in Settings."
        case let .signInFailed(message):
            message.map { "Seerr didn't accept that sign-in: \($0)" } ?? "Seerr didn't accept that sign-in."
        case .noSession:
            "Seerr accepted the sign-in but didn't start a session."
        case let .http(status, message):
            message.map { "Seerr error \(status): \($0)" } ?? "Seerr error \(status)."
        case let .decoding(detail):
            "Unexpected response from Seerr. \(detail)"
        }
    }
}

public enum SeerrMediaType: String, Sendable, Codable {
    case movie, tv
}

/// Where a title (or one season) stands on the Seerr server.
public enum SeerrAvailability: Sendable, Hashable {
    /// Nobody has asked for it yet, or an earlier request was declined.
    case requestable
    /// Requested and waiting for approval, or approved and downloading.
    case requested
    case partiallyAvailable
    case available
    /// The server's admin blocked it from being requested.
    case blocked
}

public struct SeerrSeason: Sendable, Hashable, Identifiable {
    public let number: Int
    public let name: String
    public let episodeCount: Int?
    public let availability: SeerrAvailability

    public var id: Int { number }
}

/// Someone's request for a title, or for some seasons of a show.
public struct SeerrRequest: Sendable, Hashable, Identifiable {
    public let id: Int
    public let isApproved: Bool
    public let seasons: [Int]
    public let requestedBy: String?
}

/// A title as Seerr sees it: overall status, and for a show each season's (specials left out, as Seerr does).
public struct SeerrTitle: Sendable, Hashable {
    public let availability: SeerrAvailability
    public let seasons: [SeerrSeason]
    /// The title on the media server (Jellyfin, Emby, Plex), once it's there.
    public let mediaURL: URL?

    /// Requests waiting for approval or approved, oldest first (4K ones left out).
    public let requests: [SeerrRequest]

    public var requestableSeasons: [SeerrSeason] { seasons.filter { $0.availability == .requestable } }

    /// Requested and not all there yet, so its status is worth checking again soon.
    public var isInProgress: Bool {
        availability == .requested || seasons.contains { $0.availability == .requested }
    }
}

public struct SeerrUser: Sendable, Decodable {
    public let id: Int
    public let displayName: String?
    public let username: String?
    public let jellyfinUsername: String?
    public let plexUsername: String?
    public let email: String?

    public var name: String {
        [displayName, username, jellyfinUsername, plexUsername, email].compactMap { $0 }.first { !$0.isEmpty } ?? "User \(id)"
    }
}

/// How the app proves who it is to Seerr.
public enum SeerrAuth: Codable, Sendable, Hashable {
    /// The server's API key (Seerr ▸ Settings ▸ General). Acts as the server's admin.
    case apiKey(String)
    /// The `connect.sid` session cookie from signing in with a Seerr, Jellyfin, or Emby account. Acts as that
    /// user, with their permissions (their requests may need approval). Seerr ends it after 30 days.
    case session(String)
}

/// An account to sign in to Seerr with.
public enum SeerrLogin: Sendable {
    /// A Seerr local account, by email.
    case seerr(email: String, password: String)
    /// A Jellyfin or Emby account on the media server Seerr is set up with.
    case jellyfin(username: String, password: String)
}

/// Requests movies and shows on a Seerr (Overseerr, Jellyseerr) server.
public struct SeerrClient: Sendable {
    public let baseURL: URL
    public let auth: SeerrAuth
    private let session: URLSession

    /// `server` is the address the Seerr web app opens at, such as `http://192.168.1.10:5055` or
    /// `https://requests.example.com`. A missing scheme means http, Seerr's default.
    public init?(server: String, auth: SeerrAuth, session: URLSession = SeerrClient.session) {
        let auth: SeerrAuth = switch auth {
        case let .apiKey(key): .apiKey(key.trimmingCharacters(in: .whitespacesAndNewlines))
        case let .session(cookie): .session(cookie)
        }
        guard !auth.value.isEmpty, let url = Self.normalizedURL(server) else { return nil }
        baseURL = url
        self.auth = auth
        self.session = session
    }

    public init?(server: String, apiKey: String, session: URLSession = SeerrClient.session) {
        self.init(server: server, auth: .apiKey(apiKey), session: session)
    }

    /// A self-hosted server can be offline; don't leave a spinner up for URLSession's default minute.
    /// Cookies are off: the session cookie is sent by hand, so it can't leak into other requests or linger
    /// after signing out.
    public static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }()

    /// Signs in with an account and returns a client that acts as it. The password is only sent to the server.
    public static func signIn(server: String, with login: SeerrLogin,
                              session: URLSession = SeerrClient.session) async throws -> (client: SeerrClient, user: SeerrUser) {
        guard let url = normalizedURL(server) else { throw SeerrError.invalidServer }
        let (path, body): (String, [String: String]) = switch login {
        case let .seerr(email, password): ("auth/local", ["email": email, "password": password])
        case let .jellyfin(username, password): ("auth/jellyfin", ["username": username, "password": password])
        }
        var request = URLRequest(url: url.appending(path: "api/v1/\(path)"))
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(SeerrErrorBody.self, from: data))?.message
            if (400..<500).contains(status) { throw SeerrError.signInFailed(message) }
            throw SeerrError.http(status: status, message: message)
        }
        let headers = (http?.allHeaderFields as? [String: String]) ?? [:]
        guard let cookie = HTTPCookie.cookies(withResponseHeaderFields: headers, for: request.url!)
                .first(where: { $0.name == "connect.sid" })?.value,
              let client = SeerrClient(server: url.absoluteString, auth: .session(cookie), session: session)
        else { throw SeerrError.noSession }
        do {
            return (client, try JSONDecoder().decode(SeerrUser.self, from: data))
        } catch {
            throw SeerrError.decoding(String(describing: error))
        }
    }

    /// The server's root, without a trailing slash or the `/api/v1` someone may have pasted along with it.
    static func normalizedURL(_ server: String) -> URL? {
        var text = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // Without a scheme: plain http only for a home-network address (an IP, a .local or single-label name),
        // which App Transport Security allows. It blocks http to anything else, so a public host gets https.
        if !text.contains("://") { text = (isLocalNetworkAddress(text) ? "http://" : "https://") + text }
        while text.hasSuffix("/") { text.removeLast() }
        for suffix in ["/api/v1", "/api"] where text.lowercased().hasSuffix(suffix) {
            text.removeLast(suffix.count)
        }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host() != nil else { return nil }
        return url
    }

    private static func isLocalNetworkAddress(_ address: String) -> Bool {
        let hostAndPort = address.prefix { $0 != "/" }
        if hostAndPort.hasPrefix("[") { return true } // An IPv6 literal.
        let host = hostAndPort.prefix { $0 != ":" }.lowercased()
        return !host.contains(".") || host.hasSuffix(".local") || host.allSatisfy { $0.isNumber || $0 == "." }
    }

    // MARK: Endpoints

    /// The user the API key acts as; used to check the connection.
    public func currentUser() async throws -> SeerrUser {
        try await send("auth/me")
    }

    /// Withdraws a request. Seerr lets users delete their own pending requests; admins and request managers
    /// any. Downloads Radarr or Sonarr already started aren't stopped.
    public func deleteRequest(id: Int) async throws {
        let _: SeerrEmpty = try await send("request/\(id)", method: "DELETE")
    }

    /// Ends a signed-in session on the server. Nothing to do for an API key.
    public func signOut() async throws {
        guard case .session = auth else { return }
        let _: SeerrEmpty = try await send("auth/logout", method: "POST")
    }

    public func title(_ type: SeerrMediaType, tmdbID: Int) async throws -> SeerrTitle {
        let body: SeerrDetailBody = try await send("\(type.rawValue)/\(tmdbID)")
        return SeerrTitle(body)
    }

    /// Requests a movie, or the given seasons of a show.
    public func request(_ type: SeerrMediaType, tmdbID: Int, seasons: [Int] = []) async throws {
        let body = SeerrRequestBody(mediaType: type, mediaId: tmdbID, seasons: type == .tv ? seasons.sorted() : nil)
        let _: SeerrEmpty = try await send("request", method: "POST", body: try JSONEncoder().encode(body))
    }

    // MARK: Transport

    private func send<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil) async throws -> T {
        var request = URLRequest(url: baseURL.appending(path: "api/v1/\(path)"))
        request.httpMethod = method
        request.httpBody = body
        switch auth {
        case let .apiKey(key): request.setValue(key, forHTTPHeaderField: "X-Api-Key")
        case let .session(cookie): request.setValue("connect.sid=\(cookie)", forHTTPHeaderField: "Cookie")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Seerr answers 403 both when nobody is signed in and when the user lacks a permission (say, to
        // request 4K). Checking who's signed in tells the two apart.
        if (status == 401 || status == 403) && path == "auth/me" { throw SeerrError.unauthorized }
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(SeerrErrorBody.self, from: data))?.message
            if status == 401 || status == 403 {
                // Seerr refuses with these both when the sign-in expired and when the user isn't allowed (say,
                // to delete someone else's request). Asking who's signed in tells the two apart.
                do { _ = try await currentUser() } catch SeerrError.unauthorized { throw SeerrError.unauthorized } catch {}
            }
            throw SeerrError.http(status: status, message: message)
        }
        // Deleting answers 204 with no body.
        if data.isEmpty, let empty = SeerrEmpty() as? T { return empty }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw SeerrError.decoding(String(describing: error))
        }
    }
}

extension SeerrAuth {
    var value: String {
        switch self {
        case let .apiKey(key): key
        case let .session(cookie): cookie
        }
    }
}

// MARK: - Wire format

struct SeerrRequestBody: Encodable {
    let mediaType: SeerrMediaType
    let mediaId: Int
    let seasons: [Int]?
}

struct SeerrErrorBody: Decodable {
    let message: String?
}

/// Any JSON, or none; the request endpoints' answers aren't needed.
struct SeerrEmpty: Decodable {}

/// `GET /movie/{id}` and `GET /tv/{id}`: TMDB's detail plus `mediaInfo` once the server knows the title.
struct SeerrDetailBody: Decodable {
    struct Season: Decodable {
        let seasonNumber: Int
        let name: String?
        let episodeCount: Int?
    }

    struct MediaInfo: Decodable {
        struct Season: Decodable {
            let seasonNumber: Int
            let status: Int
        }

        struct Request: Decodable {
            struct Season: Decodable {
                let seasonNumber: Int
            }

            let id: Int
            let status: Int
            let is4k: Bool?
            let seasons: [Season]?
            let requestedBy: SeerrUser?

            /// Pending approval or approved; declined, failed, and completed requests don't hold anything back.
            var isActive: Bool { (status == 1 || status == 2) && is4k != true }
        }

        let status: Int
        let seasons: [Season]?
        let requests: [Request]?
        /// Jellyseerr and Seerr call it `mediaUrl`; Overseerr, only for Plex, `plexUrl`.
        let mediaUrl: String?
        let plexUrl: String?
    }

    let seasons: [Season]?
    let mediaInfo: MediaInfo?
}

extension SeerrAvailability {
    /// Seerr's media status: 1 unknown, 2 pending, 3 processing, 4 partially available, 5 available,
    /// 6 blocklisted, 7 deleted.
    init(mediaStatus: Int) {
        switch mediaStatus {
        case 2, 3: self = .requested
        case 4: self = .partiallyAvailable
        case 5: self = .available
        case 6: self = .blocked
        default: self = .requestable
        }
    }
}

extension SeerrTitle {
    init(_ body: SeerrDetailBody) {
        let info = body.mediaInfo
        let activeRequests = (info?.requests ?? []).filter(\.isActive)
        let requestedSeasons = Set(activeRequests.flatMap { ($0.seasons ?? []).map(\.seasonNumber) })
        let seasonStatus = Dictionary((info?.seasons ?? []).map { ($0.seasonNumber, $0.status) }) { first, _ in first }

        var availability = SeerrAvailability(mediaStatus: info?.status ?? 1)
        if availability == .requestable, body.seasons == nil, !activeRequests.isEmpty { availability = .requested }

        seasons = (body.seasons ?? [])
            .filter { $0.seasonNumber > 0 }
            .sorted { $0.seasonNumber < $1.seasonNumber }
            .map { season in
                var state = SeerrAvailability(mediaStatus: seasonStatus[season.seasonNumber] ?? 1)
                if state == .requestable, requestedSeasons.contains(season.seasonNumber) { state = .requested }
                // A blocked show blocks each of its seasons.
                if availability == .blocked { state = .blocked }
                return SeerrSeason(number: season.seasonNumber, name: season.name ?? "Season \(season.seasonNumber)",
                                   episodeCount: season.episodeCount, availability: state)
            }
        self.availability = availability
        requests = activeRequests.sorted { $0.id < $1.id }.map {
            SeerrRequest(id: $0.id, isApproved: $0.status == 2, seasons: ($0.seasons ?? []).map(\.seasonNumber).sorted(),
                         requestedBy: $0.requestedBy?.name)
        }
        mediaURL = (info?.mediaUrl ?? info?.plexUrl).flatMap(URL.init(string:))
    }
}
