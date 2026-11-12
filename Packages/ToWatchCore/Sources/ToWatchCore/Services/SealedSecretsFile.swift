import CryptoKit
import Foundation
import Synchronization

#if os(macOS)
/// Secrets in a file, sealed with AES-GCM under a key that only this Mac's Secure Enclave can
/// produce. The file holds the enclave key's wrapped form, which is useless on any other Mac, so a copy of the
/// file (a backup, a synced folder) can't be read. Each save uses a fresh ephemeral key: the AES key is derived
/// from ECDH between it and the enclave key.
public final class SealedSecretsFile: Sendable {
    public static var isAvailable: Bool { SecureEnclave.isAvailable }

    /// Reading failed (the file or the enclave); trying again may work.
    public struct Unreadable: Error {}

    public let url: URL
    private static let info = Data("ToWatchDB secrets v1".utf8)

    private struct Envelope: Codable {
        /// The enclave key, wrapped by the Secure Enclave.
        var enclaveKey: Data
        var ephemeralPublicKey: Data
        var sealed: Data
        /// Set while a file the enclave refused is kept beside this one, which replaced it: the accounts saved or
        /// removed since. When the kept file opens after all, they keep this file's values (a sign-in removed
        /// here must not come back), and the others are brought back.
        var changedSinceReplacement: [String]?
    }

    /// Where a file whose key the enclave refused is kept when a save replaces it.
    private var keptURL: URL { url.appendingPathExtension("unusable") }

    /// The last secrets read or written. Every read decrypted the whole file through the Secure Enclave, and
    /// the app reads secrets at launch, for each Siri action, and for each Dropbox token refresh.
    private let cache = Mutex<[String: String]?>(nil)

    public init(url: URL) {
        self.url = url
    }

    /// Every secret, or none if there's no file. A file that can't be opened here (damaged, or sealed on
    /// another Mac) counts as none; one that couldn't be read right now throws `Unreadable`.
    public func all() throws -> [String: String] {
        if let secrets = cache.withLock({ $0 }) { return secrets }
        switch read().contents {
        case let .secrets(secrets):
            cache.withLock { $0 = secrets }
            return secrets
        case .unavailable:
            Log.secrets.error("The sealed secrets file couldn't be read")
            throw Unreadable()
        case .keyRefused, .damaged:
            // Not remembered: a file the enclave refused is tried again at the next read.
            Log.secrets.error("The sealed secrets file can't be opened on this Mac; the secrets have to be entered again")
            return [:]
        }
    }

    private enum Contents {
        case secrets([String: String])
        /// Reading the file or using the enclave failed; trying again may work.
        case unavailable
        /// The enclave wouldn't load the file's key. That's a file sealed on another Mac, which never opens here,
        /// but also what the enclave failing for once looks like, and the two can't be told apart: the file is
        /// kept when a save replaces it.
        case keyRefused
        /// The file can't ever be opened: it isn't a sealed file, or its contents don't match its key.
        case damaged
    }

    /// The secrets in the file at `url`, with its `changedSinceReplacement`.
    private static func open(_ url: URL) -> (contents: Contents, changed: [String]?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (.secrets([:]), nil) }
        guard let data = try? Data(contentsOf: url) else { return (.unavailable, nil) }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let ephemeral = try? P256.KeyAgreement.PublicKey(x963Representation: envelope.ephemeralPublicKey)
        else { return (.damaged, nil) }
        guard let enclaveKey = try? SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: envelope.enclaveKey)
        else { return (.keyRefused, nil) }
        guard let secret = try? enclaveKey.sharedSecretFromKeyAgreement(with: ephemeral) else { return (.unavailable, nil) }
        guard let box = try? AES.GCM.SealedBox(combined: envelope.sealed),
              let plain = try? AES.GCM.open(box, using: Self.symmetricKey(secret, ephemeral: ephemeral, enclave: enclaveKey.publicKey)),
              let secrets = try? JSONDecoder().decode([String: String].self, from: plain)
        else { return (.damaged, nil) }
        return (.secrets(secrets), envelope.changedSinceReplacement)
    }

    /// The file's secrets. While a refused file is kept beside it, that one is tried again first: if it opens now
    /// (the refusal was the enclave failing, not another Mac's file), the secrets it holds are brought back, except
    /// the accounts changed since, and it's removed. Replaced for good, one failed key load signed the user out of
    /// everything with no way back.
    private func read() -> (contents: Contents, changed: [String]?) {
        let (contents, changed) = Self.open(url)
        guard case let .secrets(secrets) = contents, let changed else { return (contents, nil) }
        var restored = secrets
        switch Self.open(keptURL).contents {
        case let .secrets(kept):
            for (account, value) in kept where !changed.contains(account) { restored[account] = value }
            if restored != secrets { Log.secrets.info("The secrets file kept aside opened: its secrets are back") }
        case .damaged:
            break // Nothing to bring back, ever.
        case .keyRefused, .unavailable:
            return (contents, changed) // Tried again at the next read.
        }
        guard write(restored, changed: nil) else { return (contents, changed) }
        try? FileManager.default.removeItem(at: keptURL)
        return (.secrets(restored), nil)
    }

    /// Saves `value` for `account` (nil removes it), keeping the other secrets. Returns whether it was saved.
    @discardableResult
    public func set(_ value: String?, for account: String) -> Bool {
        // Saving rewrites the whole file, so it must start from what's in it: starting from nothing after a
        // failed read dropped every other secret (saving the TMDB token signed Dropbox out). Only a file that
        // can't be opened here is replaced.
        var secrets: [String: String]
        var (contents, changed) = read()
        switch contents {
        case let .secrets(stored): secrets = stored
        case .keyRefused:
            // Kept beside the new file, and brought back by `read` if it opens later.
            try? FileManager.default.removeItem(at: keptURL)
            try? FileManager.default.copyItem(at: url, to: keptURL)
            secrets = [:]
            changed = []
        case .damaged: secrets = [:]
        case .unavailable: return false
        }
        secrets[account] = value
        if changed?.contains(account) == false { changed?.append(account) }
        return write(secrets, changed: changed)
    }

    /// Seals `secrets` into the file, replacing it. Returns whether it was written.
    private func write(_ secrets: [String: String], changed: [String]?) -> Bool {
        do {
            let enclaveKey = try existingEnclaveKey() ?? SecureEnclave.P256.KeyAgreement.PrivateKey()
            let ephemeral = P256.KeyAgreement.PrivateKey()
            let secret = try ephemeral.sharedSecretFromKeyAgreement(with: enclaveKey.publicKey)
            let key = Self.symmetricKey(secret, ephemeral: ephemeral.publicKey, enclave: enclaveKey.publicKey)
            let sealed = try AES.GCM.seal(try JSONEncoder().encode(secrets), using: key)
            guard let combined = sealed.combined else { return false }
            let envelope = Envelope(enclaveKey: enclaveKey.dataRepresentation, ephemeralPublicKey: ephemeral.publicKey.x963Representation,
                                    sealed: combined, changedSinceReplacement: changed)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(envelope).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            cache.withLock { $0 = secrets }
            return true
        } catch {
            Log.secrets.error("Couldn't seal the secrets file: \(error.localizedDescription, privacy: .public)")
            cache.withLock { $0 = nil }
            return false
        }
    }

    /// The key already in the file, so every save keeps the same one.
    private func existingEnclaveKey() throws -> SecureEnclave.P256.KeyAgreement.PrivateKey? {
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
