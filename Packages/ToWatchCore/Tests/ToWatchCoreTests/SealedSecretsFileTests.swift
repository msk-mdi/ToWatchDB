#if os(macOS)
import CryptoKit
import Foundation
import Testing
@testable import ToWatchCore

/// A file in its own temporary folder; each test reads it back through a new instance, past the cache.
private func secretsURL() -> URL {
    URL.temporaryDirectory.appending(path: "sealed-\(UUID().uuidString)/Secrets.sealed")
}

@Suite(.enabled(if: SealedSecretsFile.isAvailable))
struct SealedSecretsFileTests {
    @Test func secretsReadBackAndSavingOneKeepsTheOthers() throws {
        let url = secretsURL()
        #expect(try SealedSecretsFile(url: url).all().isEmpty) // No file yet.
        let file = SealedSecretsFile(url: url)
        #expect(file.set("tmdb", for: "tmdb-read-token"))
        #expect(file.set("dropbox", for: "dropbox-refresh-token"))
        #expect(try SealedSecretsFile(url: url).all() == ["tmdb-read-token": "tmdb", "dropbox-refresh-token": "dropbox"])

        #expect(SealedSecretsFile(url: url).set(nil, for: "tmdb-read-token"))
        #expect(try SealedSecretsFile(url: url).all() == ["dropbox-refresh-token": "dropbox"])
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        // Sealed, not written in the clear.
        #expect(try !String(decoding: Data(contentsOf: url), as: UTF8.self).contains("dropbox\""))
    }

    @Test func aDamagedFileReadsAsEmptyAndIsReplaced() throws {
        let url = secretsURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a sealed file".utf8).write(to: url)
        #expect(try SealedSecretsFile(url: url).all().isEmpty)
        #expect(SealedSecretsFile(url: url).set("key", for: "omdb-api-key"))
        #expect(try SealedSecretsFile(url: url).all() == ["omdb-api-key": "key"])
    }

    /// A sealed file whose key the enclave won't load, as one sealed on another Mac (or the enclave failing).
    private func writeRefusedFile(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let envelope = ["enclaveKey": Data("another Mac's key".utf8),
                        "ephemeralPublicKey": P256.KeyAgreement.PrivateKey().publicKey.x963Representation,
                        "sealed": Data(count: 40)]
        try JSONEncoder().encode(envelope).write(to: url)
    }

    @Test func aRefusedFileIsKeptAndItsSecretsComeBackWhenItOpens() throws {
        let url = secretsURL(), kept = url.appendingPathExtension("unusable")
        try writeRefusedFile(to: url)
        let refused = try Data(contentsOf: url)
        #expect(try SealedSecretsFile(url: url).all().isEmpty)
        #expect(SealedSecretsFile(url: url).set("new", for: "omdb-api-key"))
        #expect(SealedSecretsFile(url: url).set(nil, for: "seerr-auth"))
        #expect(try Data(contentsOf: kept) == refused)
        // Still refused: nothing comes back, and it stays.
        #expect(try SealedSecretsFile(url: url).all() == ["omdb-api-key": "new"])
        #expect(FileManager.default.fileExists(atPath: kept.path))

        // The refusal was the enclave failing for once: the kept file opens now.
        let other = secretsURL()
        let old = SealedSecretsFile(url: other)
        #expect(old.set("dropbox", for: "dropbox-refresh-token"))
        #expect(old.set("old", for: "omdb-api-key"))
        #expect(old.set("seerr", for: "seerr-auth"))
        try FileManager.default.removeItem(at: kept)
        try FileManager.default.copyItem(at: other, to: kept)
        // What was saved or removed since keeps its value; the rest is back.
        #expect(try SealedSecretsFile(url: url).all() == ["omdb-api-key": "new", "dropbox-refresh-token": "dropbox"])
        #expect(!FileManager.default.fileExists(atPath: kept.path))
        #expect(SealedSecretsFile(url: url).set("tmdb", for: "tmdb-read-token"))
        #expect(try SealedSecretsFile(url: url).all().count == 3)
    }

    @Test func aFileThatCantBeReadIsNeitherEmptyNorOverwritten() throws {
        let url = secretsURL()
        #expect(SealedSecretsFile(url: url).set("dropbox", for: "dropbox-refresh-token"))
        let sealed = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }

        // Read as "nothing saved", a locked file signed Dropbox out; saved over, it lost every other secret.
        #expect(throws: SealedSecretsFile.Unreadable.self) { try SealedSecretsFile(url: url).all() }
        #expect(!SealedSecretsFile(url: url).set("tmdb", for: "tmdb-read-token"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #expect(try Data(contentsOf: url) == sealed)
        #expect(try SealedSecretsFile(url: url).all() == ["dropbox-refresh-token": "dropbox"])
    }
}
#endif
