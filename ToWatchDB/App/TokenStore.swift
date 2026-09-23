import Foundation
import Security

/// Stores the user's optional TMDB token override in the Keychain.
enum TokenStore {
    private static let service = "com.mehdi.towatchdb"
    private static let account = "tmdb-read-token"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ token: String) -> Bool {
        delete()
        var query = baseQuery
        query[kSecValueData as String] = Data(token.utf8)
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    /// Token baked in at build time from `Config/Secrets.xcconfig`, if any.
    static var bundledToken: String? {
        guard let token = Bundle.main.object(forInfoDictionaryKey: "TMDBReadToken") as? String,
              !token.isEmpty, !token.hasPrefix("$(") else { return nil }
        return token
    }
}
