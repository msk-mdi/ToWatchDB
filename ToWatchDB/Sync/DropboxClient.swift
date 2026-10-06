import CryptoKit
import Foundation

/// The few Dropbox HTTP endpoints sync needs: OAuth with PKCE (no client secret in the app), and downloading
/// and uploading one file in the app's folder (Dropbox ▸ Apps ▸ ToWatchDB).
struct DropboxClient: Sendable {
    let appKey: String

    /// From `DROPBOX_APP_KEY` in `Config/Secrets.xcconfig`. The key isn't secret: PKCE needs no client secret.
    static var bundledAppKey: String? {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "DropboxAppKey") as? String,
              !key.isEmpty, !key.hasPrefix("$(") else { return nil }
        return key
    }

    /// Dropbox treats `db-<app key>` as the app's own redirect scheme; the sign-in sheet catches it.
    var callbackScheme: String { "db-\(appKey)" }
    private var redirectURI: String { "\(callbackScheme)://2/token" }

    struct Tokens: Decodable {
        let accessToken: String
        let expiresIn: Double
        let refreshToken: String?
    }

    /// A file's contents and revision, which an upload passes back so it can't overwrite a newer file.
    struct File {
        let data: Data
        let rev: String
    }

    // MARK: Sign-in

    /// A random PKCE verifier; the sign-in URL carries its hash.
    static func makeVerifier() -> String {
        let characters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        return String((0..<64).map { _ in characters.randomElement(using: &generator)! })
    }

    func authorizeURL(verifier: String) -> URL {
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
    func code(fromCallback url: URL) throws -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let code = items.first(where: { $0.name == "code" })?.value { return code }
        let reason = items.first(where: { $0.name == "error_description" })?.value
            ?? items.first(where: { $0.name == "error" })?.value
        throw DropboxError.signInFailed(reason ?? "Dropbox didn't return an authorization code.")
    }

    func exchange(code: String, verifier: String) async throws -> Tokens {
        try await tokenRequest(["code": code, "grant_type": "authorization_code", "client_id": appKey,
                                "code_verifier": verifier, "redirect_uri": redirectURI])
    }

    func refresh(_ refreshToken: String) async throws -> Tokens {
        try await tokenRequest(["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": appKey])
    }

    private func tokenRequest(_ form: [String: String]) async throws -> Tokens {
        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((body.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // A refresh token the user revoked (or an expired code) comes back as 400 invalid_grant.
        if status == 400, String(decoding: data, as: UTF8.self).contains("invalid_grant") { throw DropboxError.signedOut }
        guard status == 200 else { throw DropboxError.http(status, Self.summary(data)) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Tokens.self, from: data)
    }

    /// Ends the session on Dropbox's side too. Best effort: disconnecting works offline.
    func revoke(accessToken: String) async {
        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/auth/token/revoke")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: request)
    }

    /// The signed-in account's email, shown in Settings.
    func accountEmail(accessToken: String) async throws -> String? {
        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/users/get_current_account")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("null".utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
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
    func download(path: String, accessToken: String) async throws -> File? {
        var request = URLRequest(url: URL(string: "https://content.dropboxapi.com/2/files/download")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(try Self.argument(["path": path]), forHTTPHeaderField: "Dropbox-API-Arg")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 409, Self.summary(data).hasPrefix("path/not_found") { return nil }
        try Self.check(response, data)
        struct Metadata: Decodable { let rev: String }
        let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Dropbox-API-Result") ?? ""
        let metadata = try JSONDecoder().decode(Metadata.self, from: Data(header.utf8))
        return File(data: data, rev: metadata.rev)
    }

    /// Writes the file. With `replacing`, only if it's still at that revision; otherwise only if there's none.
    /// Throws `DropboxError.conflict` if another device wrote it first.
    @discardableResult
    func upload(_ data: Data, path: String, replacing rev: String?, accessToken: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://content.dropboxapi.com/2/files/upload")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let mode: Any = rev.map { [".tag": "update", "update": $0] } ?? "add"
        request.setValue(try Self.argument(["path": path, "mode": mode, "autorename": false, "mute": true]),
                         forHTTPHeaderField: "Dropbox-API-Arg")
        request.httpBody = data
        let (body, response) = try await URLSession.shared.data(for: request)
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

enum DropboxError: LocalizedError {
    case notConfigured
    case signInFailed(String)
    /// The sign-in was revoked, from Dropbox's website or another device.
    case signedOut
    case expiredAccessToken
    case conflict
    case rateLimited
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "This build has no Dropbox app key. Set DROPBOX_APP_KEY in Config/Secrets.xcconfig."
        case let .signInFailed(reason): "Couldn't connect to Dropbox: \(reason)"
        case .signedOut: "Dropbox signed this device out. Connect again to keep syncing."
        case .expiredAccessToken: "The Dropbox session expired."
        case .conflict: "Another device changed the library on Dropbox at the same time. Try again."
        case .rateLimited: "Dropbox is busy. Sync will try again later."
        case let .http(status, summary): "Dropbox returned an error (\(status)): \(summary)"
        }
    }
}
