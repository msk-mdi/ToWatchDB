#if os(macOS)
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
