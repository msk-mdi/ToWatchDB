import Foundation
import Security

/// Stores the user's optional TMDB token override in the Keychain.
enum TokenStore {
    private static let account = "tmdb-read-token"

    static func load() -> String? { Keychain.load(account) }

    @discardableResult
    static func save(_ token: String) -> Bool { Keychain.save(token, account: account) }

    static func delete() { Keychain.delete(account) }

    /// Token baked in at build time from `Config/Secrets.xcconfig`, if any.
    static var bundledToken: String? {
        guard let token = Bundle.main.object(forInfoDictionaryKey: "TMDBReadToken") as? String,
              !token.isEmpty, !token.hasPrefix("$(") else { return nil }
        return token
    }
}

/// Generic passwords for the app's secrets: the TMDB token and the Dropbox sign-in.
enum Keychain {
    private static let service = "com.mehdi.towatchdb"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load(_ account: String) -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ value: String, account: String) -> Bool {
        delete(account)
        var query = query(account)
        query[kSecValueData as String] = Data(value.utf8)
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
