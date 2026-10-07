import Foundation
import ToWatchCore
import Security
#if os(macOS)
import CryptoKit
import Synchronization
#endif

/// Stores the user's optional TMDB token override (see `SecretStore` for where).
enum TokenStore {
    private static let account = "tmdb-read-token"

    static func load() -> String? { SecretStore.load(account) }

    static func read() throws -> String? { try SecretStore.read(account) }

    @discardableResult
    static func save(_ token: String) -> Bool { SecretStore.save(token, account: account) }

    static func delete() { SecretStore.delete(account) }

    /// Token baked in at build time from `Config/Secrets.xcconfig`, if any.
    static var bundledToken: String? {
        guard let token = Bundle.main.object(forInfoDictionaryKey: "TMDBReadToken") as? String,
              !token.isEmpty, !token.hasPrefix("$(") else { return nil }
        return token
    }
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

    static func delete() { SecretStore.delete(account) }
}

/// The app's secrets: the TMDB token, the Dropbox sign-in, and the Seerr API key.
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

    static func delete(_ account: String) {
        #if os(macOS)
        if EnclaveSecrets.isAvailable { EnclaveSecrets.set(nil, for: account) }
        #endif
        // On macOS, also an item an earlier version saved and never moved.
        Keychain.delete(account)
    }
}

#if os(macOS)
/// Secrets in Application Support, sealed with AES-GCM under a key that only this Mac's Secure Enclave can
/// produce. The file holds the enclave key's wrapped form, which is useless on any other Mac, so a copy of the
/// file (a backup, a synced folder) can't be read. Each save uses a fresh ephemeral key: the AES key is derived
/// from ECDH between it and the enclave key.
enum EnclaveSecrets {
    static var isAvailable: Bool { SecureEnclave.isAvailable }

    private static var url: URL { .applicationSupportDirectory.appending(path: "Secrets.sealed") }
    private static let info = Data("ToWatchDB secrets v1".utf8)

    private struct Envelope: Codable {
        /// The enclave key, wrapped by the Secure Enclave.
        var enclaveKey: Data
        var ephemeralPublicKey: Data
        var sealed: Data
    }

    /// The last secrets read or written. Every read decrypted the whole file through the Secure Enclave, and
    /// the app reads secrets at launch, for each Siri action, and for each Dropbox token refresh.
    private static let cache = Mutex<[String: String]?>(nil)

    static func all() throws -> [String: String] {
        if let secrets = cache.withLock({ $0 }) { return secrets }
        switch read() {
        case let .secrets(secrets):
            cache.withLock { $0 = secrets }
            return secrets
        case .unavailable: throw SecretStore.Unreadable()
        case .unusable: return [:] // Made on another Mac or damaged: the secrets have to be entered again.
        }
    }

    private enum Contents {
        case secrets([String: String])
        /// Reading the file or using the enclave failed; trying again may work.
        case unavailable
        /// The file can't ever be opened here: damaged, or sealed on another Mac.
        case unusable
    }

    private static func read() -> Contents {
        guard FileManager.default.fileExists(atPath: url.path) else { return .secrets([:]) }
        guard let data = try? Data(contentsOf: url) else { return .unavailable }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let enclaveKey = try? SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: envelope.enclaveKey),
              let ephemeral = try? P256.KeyAgreement.PublicKey(x963Representation: envelope.ephemeralPublicKey)
        else { return .unusable }
        guard let secret = try? enclaveKey.sharedSecretFromKeyAgreement(with: ephemeral) else { return .unavailable }
        guard let box = try? AES.GCM.SealedBox(combined: envelope.sealed),
              let plain = try? AES.GCM.open(box, using: symmetricKey(secret, ephemeral: ephemeral, enclave: enclaveKey.publicKey)),
              let secrets = try? JSONDecoder().decode([String: String].self, from: plain)
        else { return .unusable }
        return .secrets(secrets)
    }

    @discardableResult
    static func set(_ value: String?, for account: String) -> Bool {
        // Saving rewrites the whole file, so it must start from what's in it: starting from nothing after a
        // failed read dropped every other secret (saving the TMDB token signed Dropbox out). Only a file that
        // can never be opened here is replaced.
        var secrets: [String: String]
        switch read() {
        case let .secrets(stored): secrets = stored
        case .unusable: secrets = [:]
        case .unavailable: return false
        }
        secrets[account] = value
        do {
            let enclaveKey = try existingEnclaveKey() ?? SecureEnclave.P256.KeyAgreement.PrivateKey()
            let ephemeral = P256.KeyAgreement.PrivateKey()
            let secret = try ephemeral.sharedSecretFromKeyAgreement(with: enclaveKey.publicKey)
            let key = symmetricKey(secret, ephemeral: ephemeral.publicKey, enclave: enclaveKey.publicKey)
            let sealed = try AES.GCM.seal(try JSONEncoder().encode(secrets), using: key)
            guard let combined = sealed.combined else { return false }
            let envelope = Envelope(enclaveKey: enclaveKey.dataRepresentation,
                                    ephemeralPublicKey: ephemeral.publicKey.x963Representation, sealed: combined)
            try FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(envelope).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            cache.withLock { $0 = secrets }
            return true
        } catch {
            cache.withLock { $0 = nil }
            return false
        }
    }

    /// The key already in the file, so every save keeps the same one.
    private static func existingEnclaveKey() throws -> SecureEnclave.P256.KeyAgreement.PrivateKey? {
        guard let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
        return try? SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: envelope.enclaveKey)
    }

    private static func symmetricKey(_ secret: SharedSecret, ephemeral: P256.KeyAgreement.PublicKey,
                                     enclave: P256.KeyAgreement.PublicKey) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: ephemeral.x963Representation,
                                       sharedInfo: info + enclave.x963Representation, outputByteCount: 32)
    }
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
    private static var accessibility: [String: Any] { [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock] }
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
              let data = item[kSecValueData as String] as? Data else { throw SecretStore.Unreadable() }
        #if os(iOS)
        // Items saved before were readable only while unlocked.
        if item[kSecAttrAccessible as String] as? String != kSecAttrAccessibleAfterFirstUnlock as String {
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

    static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
