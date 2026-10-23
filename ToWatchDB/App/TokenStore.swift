import Foundation
import Security
import ToWatchCore
#if os(macOS)
import Synchronization
#endif

/// Stores the user's optional TMDB token override (see `SecretStore` for where).
enum TokenStore {
    private static let account = "tmdb-read-token"

    static func load() -> String? { SecretStore.load(account) }

    static func read() throws -> String? { try SecretStore.read(account) }

    @discardableResult
    static func save(_ token: String) -> Bool { SecretStore.save(token, account: account) }

    @discardableResult
    static func delete() -> Bool { SecretStore.delete(account) }

    /// Token baked in at build time from `Config/Secrets.xcconfig`, if any.
    static var bundledToken: String? {
        guard let token = Bundle.main.object(forInfoDictionaryKey: "TMDBReadToken") as? String,
              !token.isEmpty, !token.hasPrefix("$(") else { return nil }
        return token
    }
}

extension DropboxSync.Vault {
    /// The Dropbox sign-in, kept with the other secrets (see `SecretStore`).
    static let secretStore: Self = {
        let account = "dropbox-refresh-token"
        return Self(read: { try SecretStore.read(account) },
                    save: { SecretStore.save($0, account: account) },
                    delete: { SecretStore.delete(account) })
    }()
}

/// The user's OMDb API key, for IMDb ratings (see `SecretStore` for where).
enum OMDbKeyStore {
    private static let account = "omdb-api-key"

    static func load() -> String? { SecretStore.load(account) }

    static func read() throws -> String? { try SecretStore.read(account) }

    @discardableResult
    static func save(_ key: String) -> Bool { SecretStore.save(key, account: account) }

    @discardableResult
    static func delete() -> Bool { SecretStore.delete(account) }
}

/// The Seerr API key or sign-in session, kept with the other secrets (see `SecretStore`).
enum SeerrAuthStore {
    private static let account = "seerr-auth"

    static func load() -> SeerrAuth? { (try? read()) ?? nil }

    static func read() throws -> SeerrAuth? {
        try SecretStore.read(account).flatMap { try? JSONDecoder().decode(SeerrAuth.self, from: Data($0.utf8)) }
    }

    @discardableResult
    static func save(_ auth: SeerrAuth) -> Bool {
        guard let data = try? JSONEncoder().encode(auth) else { return false }
        return SecretStore.save(String(decoding: data, as: UTF8.self), account: account)
    }

    @discardableResult
    static func delete() -> Bool { SecretStore.delete(account) }
}

/// The app's secrets: the TMDB token, the OMDb key, the Dropbox sign-in, and the Seerr API key.
///
/// iOS keeps them in the Keychain. On macOS the app is signed ad hoc, so the Keychain knows it only by the hash
/// of one exact build and asked for the login password after every update. There they're kept in a file
/// encrypted with a Secure Enclave key instead (`EnclaveSecrets`). Macs without a Secure Enclave keep the Keychain.
enum SecretStore {
    /// The secrets couldn't be read right now (a locked iPhone, a busy Secure Enclave); trying later may work.
    struct Unreadable: Error {}

    /// The stored value, or nil if there's none. Throws `Unreadable` when reading failed, so a locked device
    /// isn't taken for a signed-out one (that signed Dropbox out and deleted the sync base).
    static func read(_ account: String) throws -> String? {
        #if os(macOS)
        guard EnclaveSecrets.isAvailable else { return try Keychain.read(account) }
        if let value = try EnclaveSecrets.all()[account] { return value }
        // Moves an item an earlier version saved in the Keychain (one last password prompt). Looked for once per
        // launch: an account that isn't set was looked up in the Keychain on every read.
        guard checkedKeychain.withLock({ $0.insert(account).inserted }),
              let value = try? Keychain.read(account) else { return nil }
        if EnclaveSecrets.set(value, for: account) { Keychain.delete(account) }
        return value
        #else
        try Keychain.read(account)
        #endif
    }

    /// The stored value, or nil if there's none or it couldn't be read.
    static func load(_ account: String) -> String? { (try? read(account)) ?? nil }

    #if os(macOS)
    private static let checkedKeychain = Mutex<Set<String>>([])
    #endif

    @discardableResult
    static func save(_ value: String, account: String) -> Bool {
        #if os(macOS)
        if EnclaveSecrets.isAvailable { return EnclaveSecrets.set(value, for: account) }
        #endif
        return Keychain.save(value, account: account)
    }

    /// Whether the value is gone. It can stay when the secrets can't be written right now (a locked iPhone).
    @discardableResult
    static func delete(_ account: String) -> Bool {
        // On macOS, also an item an earlier version saved and never moved.
        let isKeychainClear = Keychain.delete(account)
        #if os(macOS)
        if EnclaveSecrets.isAvailable { return EnclaveSecrets.set(nil, for: account) }
        #endif
        return isKeychainClear
    }
}

#if os(macOS)
/// The app's secrets file in Application Support (`SealedSecretsFile`).
enum EnclaveSecrets {
    static var isAvailable: Bool { SealedSecretsFile.isAvailable }

    private static let file = SealedSecretsFile(url: .applicationSupportDirectory.appending(path: "Secrets.sealed"))

    static func all() throws -> [String: String] { try file.all() }

    @discardableResult
    static func set(_ value: String?, for account: String) -> Bool { file.set(value, for: account) }
}
#endif

/// Generic passwords in the Keychain.
private enum Keychain {
    private static let service = "com.mehdi.towatchdb"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    #if os(iOS)
    /// Readable after the first unlock, so a sync or Siri action while the iPhone is locked can use the secrets.
    /// This device only: a Dropbox sign-in or Seerr key shouldn't follow a backup onto another device.
    private static var accessibility: [String: Any] { [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] }
    #else
    private static var accessibility: [String: Any] { [:] }
    #endif

    /// The value, or nil if there's none. Throws if the Keychain couldn't be read (the device is locked).
    static func read(_ account: String) throws -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let item = result as? [String: Any],
              let data = item[kSecValueData as String] as? Data else {
            Log.secrets.error("Keychain read failed (status \(status, privacy: .public))")
            throw SecretStore.Unreadable()
        }
        #if os(iOS)
        // Items saved before were readable only while unlocked, or not bound to this device.
        if item[kSecAttrAccessible as String] as? String != kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String {
            SecItemUpdate(self.query(account) as CFDictionary, accessibility as CFDictionary)
        }
        #endif
        return String(data: data, encoding: .utf8)
    }

    /// Updates the item in place: deleting first lost the old value when adding then failed.
    @discardableResult
    static func save(_ value: String, account: String) -> Bool {
        let attributes = accessibility.merging([kSecValueData as String: Data(value.utf8)]) { $1 }
        let status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        guard status == errSecItemNotFound else { return status == errSecSuccess }
        return SecItemAdd(query(account).merging(attributes) { $1 } as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete(_ account: String) -> Bool {
        let status = SecItemDelete(query(account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
