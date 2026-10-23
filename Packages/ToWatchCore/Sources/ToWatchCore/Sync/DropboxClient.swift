import CryptoKit
import Foundation

/// The few Dropbox HTTP endpoints sync needs: OAuth with PKCE (no client secret in the app), and downloading
/// and uploading one file in the app's folder (Dropbox ▸ Apps ▸ ToWatchDB).
public struct DropboxClient: Sendable {
    public let appKey: String
    private let session: URLSession

    public init(appKey: String, session: URLSession = DropboxClient.session) {
        self.appKey = appKey
        self.session = session
    }

    /// From `DROPBOX_APP_KEY` in `Config/Secrets.xcconfig`. The key isn't secret: PKCE needs no client secret.
    public static var bundledAppKey: String? {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "DropboxAppKey") as? String,
              !key.isEmpty, !key.hasPrefix("$(") else { return nil }
        return key
    }

    /// A stalled connection otherwise held a sync for URLSession's default minute per request, up to four in a
    /// row, and the launch refresh waits for a running sync. The timeout is for silence, not for the whole
    /// transfer, so a slow upload of a large library still finishes. No URL cache: the bodies are the library
    /// and the tokens.
    public static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }()

    /// Dropbox treats `db-<app key>` as the app's own redirect scheme; the sign-in sheet catches it.
    public var callbackScheme: String { "db-\(appKey)" }
    private var redirectURI: String { "\(callbackScheme)://2/token" }

    public struct Tokens: Decodable, Sendable {
        public let accessToken: String
        public let expiresIn: Double
        public let refreshToken: String?
    }

    /// A file's contents and revision, which an upload passes back so it can't overwrite a newer file.
    public struct File: Sendable {
        public let data: Data
        public let rev: String

        public init(data: Data, rev: String) {
            self.data = data
            self.rev = rev
        }
    }

    // MARK: Sign-in

    /// A random PKCE verifier; the sign-in URL carries its hash.
    public static func makeVerifier() -> String {
        let characters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        return String((0..<64).map { _ in characters.randomElement(using: &generator)! })
    }

    public func authorizeURL(verifier: String) -> URL {
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        var components = URLComponents(string: "https://www.dropbox.com/oauth2/authorize")!
        components.queryItems = [
            .init(name: "client_id", value: appKey),
            .init(name: "response_type", value: "code"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "token_access_type", value: "offline"),
            .init(name: "redirect_uri", value: redirectURI),
        ]
        return components.url!
    }

    /// The authorization code from the redirect, or the reason sign-in was refused.
    public func code(fromCallback url: URL) throws -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let code = items.first(where: { $0.name == "code" })?.value { return code }
        let reason = items.first(where: { $0.name == "error_description" })?.value
            ?? items.first(where: { $0.name == "error" })?.value
        throw DropboxError.signInFailed(reason ?? "Dropbox didn't return an authorization code.")
    }

    public func exchange(code: String, verifier: String) async throws -> Tokens {
        try await tokenRequest(["code": code, "grant_type": "authorization_code", "client_id": appKey,
                                "code_verifier": verifier, "redirect_uri": redirectURI], invalidGrant: .signInFailed("The sign-in code expired. Try again."))
    }

    public func refresh(_ refreshToken: String) async throws -> Tokens {
        try await tokenRequest(["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": appKey],
                               invalidGrant: .signedOut)
    }

    /// `invalidGrant` is thrown for a 400 invalid_grant: a revoked refresh token signs the device out, while an
    /// expired or reused code only fails that sign-in.
    private func tokenRequest(_ form: [String: String], invalidGrant: DropboxError) async throws -> Tokens {
        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((body.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 400, String(decoding: data, as: UTF8.self).contains("invalid_grant") { throw invalidGrant }
        guard status == 200 else { throw DropboxError.http(status, Self.summary(data)) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Tokens.self, from: data)
    }

    /// Ends the session on Dropbox's side too. Best effort: disconnecting works offline.
    public func revoke(accessToken: String) async {
        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/auth/token/revoke")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        _ = try? await session.data(for: request)
    }

    /// The signed-in account's email, shown in Settings.
    public func accountEmail(accessToken: String) async throws -> String? {
        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/users/get_current_account")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("null".utf8)
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data)
        struct Account: Decodable {
            struct Name: Decodable { let display_name: String }
            let email: String?
            let name: Name
        }
        let account = try JSONDecoder().decode(Account.self, from: data)
        return account.email ?? account.name.display_name
    }

    // MARK: Files

    /// The file, or nil if there isn't one yet.
    public func download(path: String, accessToken: String) async throws -> File? {
        var request = URLRequest(url: URL(string: "https://content.dropboxapi.com/2/files/download")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(try Self.argument(["path": path]), forHTTPHeaderField: "Dropbox-API-Arg")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, response) = try await session.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 409, Self.summary(data).hasPrefix("path/not_found") { return nil }
        try Self.check(response, data)
        struct Metadata: Decodable { let rev: String }
        let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Dropbox-API-Result") ?? ""
        let metadata = try JSONDecoder().decode(Metadata.self, from: Data(header.utf8))
        return File(data: data, rev: metadata.rev)
    }

    /// The file's revision, or nil if there isn't one yet. Much cheaper than downloading it to see if it changed.
    public func revision(path: String, accessToken: String) async throws -> String? {
        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/files/get_metadata")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(try Self.argument(["path": path]).utf8)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, response) = try await session.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 409, Self.summary(data).hasPrefix("path/not_found") { return nil }
        try Self.check(response, data)
        struct Metadata: Decodable { let rev: String? }
        return try JSONDecoder().decode(Metadata.self, from: data).rev
    }

    /// Writes the file. With `replacing`, only if it's still at that revision; otherwise only if there's none.
    /// Throws `DropboxError.conflict` if another device wrote it first.
    @discardableResult
    public func upload(_ data: Data, path: String, replacing rev: String?, accessToken: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://content.dropboxapi.com/2/files/upload")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let mode: Any = rev.map { [".tag": "update", "update": $0] } ?? "add"
        request.setValue(try Self.argument(["path": path, "mode": mode, "autorename": false, "mute": true]),
                         forHTTPHeaderField: "Dropbox-API-Arg")
        request.httpBody = data
        let (body, response) = try await session.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 409, Self.summary(body).contains("conflict") {
            throw DropboxError.conflict
        }
        try Self.check(response, body)
        struct Metadata: Decodable { let rev: String }
        return try JSONDecoder().decode(Metadata.self, from: body).rev
    }

    // MARK: Helpers

    /// The JSON argument header. Dropbox wants non-ASCII characters escaped; the paths used here are ASCII.
    private static func argument(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return
        case 401: throw DropboxError.expiredAccessToken
        case 429: throw DropboxError.rateLimited
        default: throw DropboxError.http(status, summary(data))
        }
    }

    /// Dropbox errors carry an `error_summary` like "path/not_found/..".
    private static func summary(_ data: Data) -> String {
        struct Failure: Decodable {
            let error_summary: String?
            let error_description: String?
        }
        let failure = try? JSONDecoder().decode(Failure.self, from: data)
        return failure?.error_summary ?? failure?.error_description ?? String(decoding: data.prefix(200), as: UTF8.self)
    }
}

public enum DropboxError: LocalizedError, Sendable {
    case notConfigured
    case signInFailed(String)
    /// The sign-in was revoked, from Dropbox's website or another device.
    case signedOut
    /// The sign-in saved on this device couldn't be read right now (the iPhone is locked).
    case secretsUnavailable
    case expiredAccessToken
    case conflict
    case rateLimited
    case http(Int, String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "This build has no Dropbox app key. Set DROPBOX_APP_KEY in Config/Secrets.xcconfig."
        case let .signInFailed(reason): "Couldn't connect to Dropbox: \(reason)"
        case .signedOut: "Dropbox signed this device out. Connect again to keep syncing."
        case .secretsUnavailable: "The Dropbox sign-in couldn't be read. Sync will try again later."
        case .expiredAccessToken: "The Dropbox session expired."
        case .conflict: "Another device changed the library on Dropbox at the same time. Try again."
        case .rateLimited: "Dropbox is busy. Sync will try again later."
        case let .http(status, summary): "Dropbox returned an error (\(status)): \(summary)"
        }
    }
}
