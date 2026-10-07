import Foundation
import Security
#if os(macOS)
import CryptoKit
#endif

/// Stores the user's optional TMDB token override (see `SecretStore` for where).
enum TokenStore {
    private static let account = "tmdb-read-token"

    static func load() -> String? { SecretStore.load(account) }

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

/// The app's secrets: the TMDB token and the Dropbox sign-in.
///
/// iOS keeps them in the Keychain. On macOS the app is signed ad hoc, so the Keychain knows it only by the hash
/// of one exact build and asked for the login password after every update. There they're kept in a file
/// encrypted with a Secure Enclave key instead (`EnclaveSecrets`). Macs without a Secure Enclave keep the Keychain.
enum SecretStore {
    static func load(_ account: String) -> String? {
        #if os(macOS)
        guard EnclaveSecrets.isAvailable else { return Keychain.load(account) }
        if let value = EnclaveSecrets.all()[account] { return value }
        // Moves an item an earlier version saved in the Keychain (one last password prompt).
        guard let value = Keychain.load(account) else { return nil }
        if EnclaveSecrets.set(value, for: account) { Keychain.delete(account) }
        return value
        #else
        Keychain.load(account)
        #endif
    }

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

    static func all() -> [String: String] {
        if case let .secrets(secrets) = read() { return secrets }
        return [:] // Unreadable, or made on another Mac: the secrets have to be entered again.
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
            return true
        } catch {
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
