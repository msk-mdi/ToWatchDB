import AuthenticationServices
import Foundation
import Observation
import ToWatchCore

/// Keeps the library in sync with a file in the user's Dropbox, so every device signed in to the same
/// Dropbox account sees the same library. See `LibrarySync` for how changes from both sides are merged.
@Observable @MainActor
final class DropboxSync {
    /// In the app's folder: Dropbox ▸ Apps ▸ ToWatchDB.
    static let path = "/ToWatchDB Library.json"
    private static let refreshTokenAccount = "dropbox-refresh-token"

    let client: DropboxClient? = DropboxClient.bundledAppKey.map(DropboxClient.init)

    private(set) var isConnected = SecretStore.load(refreshTokenAccount) != nil
    private(set) var isSyncing = false
    private(set) var lastError: String?

    private(set) var accountEmail: String? = UserDefaults.standard.string(forKey: "dropboxAccount") {
        didSet { UserDefaults.standard.set(accountEmail, forKey: "dropboxAccount") }
    }

    private(set) var lastSynced: Date? = UserDefaults.standard.object(forKey: "dropboxLastSynced") as? Date {
        didSet { UserDefaults.standard.set(lastSynced, forKey: "dropboxLastSynced") }
    }

    /// The library version the last sync uploaded or found already in Dropbox. A save after it needs a sync.
    private(set) var syncedVersion: Int?

    @ObservationIgnored private var accessToken: (value: String, expires: Date)?
    /// A sync asked for while one was running; it runs right after, so a change made meanwhile isn't missed.
    @ObservationIgnored private var needsAnotherPass = false

    // MARK: Connecting

    /// Signs in with Dropbox in a web sheet. `authenticate` presents it and returns the redirect URL.
    func connect(authenticate: (URL, String) async throws -> URL) async {
        guard let client else {
            lastError = DropboxError.notConfigured.localizedDescription
            return
        }
        do {
            let verifier = DropboxClient.makeVerifier()
            let callback = try await authenticate(client.authorizeURL(verifier: verifier), client.callbackScheme)
            let tokens = try await client.exchange(code: client.code(fromCallback: callback), verifier: verifier)
            guard let refreshToken = tokens.refreshToken else {
                throw DropboxError.signInFailed("Dropbox didn't grant offline access.")
            }
            SecretStore.save(refreshToken, account: Self.refreshTokenAccount)
            accessToken = (tokens.accessToken, .now.addingTimeInterval(tokens.expiresIn - 60))
            // A different account's file has nothing to do with the last one's.
            try? FileManager.default.removeItem(at: Self.baseURL)
            lastSynced = nil
            syncedVersion = nil
            lastError = nil
            isConnected = true
            accountEmail = try? await client.accountEmail(accessToken: tokens.accessToken)
        } catch {
            // Closing the sign-in sheet isn't an error worth showing.
            if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin || error is CancellationError { return }
            lastError = error.localizedDescription
        }
    }

    /// Signs out and forgets the sync state. The library on this device and the file in Dropbox stay.
    func disconnect() {
        if let client, let token = accessToken?.value {
            Task { await client.revoke(accessToken: token) }
        }
        SecretStore.delete(Self.refreshTokenAccount)
        try? FileManager.default.removeItem(at: Self.baseURL)
        accessToken = nil
        accountEmail = nil
        lastSynced = nil
        lastError = nil
        syncedVersion = nil
        isConnected = false
    }

    // MARK: Syncing

    /// Downloads the file, merges it with the library, and uploads the result if it changed.
    /// `library` must be read fresh after each await; `version` is the library's current save count.
    func sync(library: @escaping () -> LibraryService, version: @escaping () -> Int) async {
        guard isConnected, let client else { return }
        guard !isSyncing else {
            needsAnotherPass = true
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            needsAnotherPass = false
            await syncOnce(client: client, library: library, version: version)
        } while needsAnotherPass && isConnected && lastError == nil
    }

    private func syncOnce(client: DropboxClient, library: () -> LibraryService, version: () -> Int) async {
        // A conflict means another device uploaded between our download and upload: merge again with its file.
        for attempt in 1...3 {
            do {
                let file = try await authorized { try await client.download(path: Self.path, accessToken: $0) }
                let remote = try file.map { try BackupCoding.decode($0.data) }

                // From here to the snapshot nothing awaits, so no edit can slip in between merge and upload.
                let service = library()
                if let remote {
                    let merged = LibrarySync.merge(base: loadBase(), local: try service.makeBackup(), remote: remote)
                    try service.applySyncedBackup(merged)
                }
                let snapshot = LibrarySync.normalized(try service.makeBackup())
                let snapshotVersion = version()
                let data = try BackupCoding.encoder.encode(snapshot)

                if remote.map({ !LibrarySync.sameContent($0, snapshot) }) ?? true {
                    try await authorized {
                        try await client.upload(data, path: Self.path, replacing: file?.rev, accessToken: $0)
                    }
                }
                saveBase(data)
                syncedVersion = snapshotVersion
                lastSynced = .now
                lastError = nil
                return
            } catch DropboxError.conflict where attempt < 3 {
                continue
            } catch DropboxError.signedOut {
                disconnect()
                lastError = DropboxError.signedOut.localizedDescription
                return
            } catch is CancellationError {
                return
            } catch {
                lastError = error.localizedDescription
                return
            }
        }
    }

    /// Runs a request with a valid access token, refreshing it first if it expired.
    private func authorized<T>(_ request: (String) async throws -> T) async throws -> T {
        do {
            return try await request(try await validAccessToken())
        } catch DropboxError.expiredAccessToken {
            accessToken = nil
            return try await request(try await validAccessToken())
        }
    }

    private func validAccessToken() async throws -> String {
        if let accessToken, accessToken.expires > .now { return accessToken.value }
        guard let client, let refreshToken = SecretStore.load(Self.refreshTokenAccount) else { throw DropboxError.signedOut }
        let tokens = try await client.refresh(refreshToken)
        accessToken = (tokens.accessToken, .now.addingTimeInterval(tokens.expiresIn - 60))
        return tokens.accessToken
    }

    // MARK: Base snapshot

    /// The library as of the last sync, so the next one can tell what changed on each side.
    private static var baseURL: URL {
        URL.applicationSupportDirectory.appending(path: "Dropbox Sync Base.json")
    }

    private func loadBase() -> LibraryBackup? {
        guard let data = try? Data(contentsOf: Self.baseURL) else { return nil }
        return try? BackupCoding.decode(data)
    }

    private func saveBase(_ data: Data) {
        try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        try? data.write(to: Self.baseURL, options: .atomic)
    }
}
