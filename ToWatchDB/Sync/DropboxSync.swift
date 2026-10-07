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
    /// Bumped by connecting and disconnecting. A sync started under an older session stops at its next step:
    /// it mustn't upload one account's library with another's token, or report "signed out" after the user
    /// disconnected on purpose.
    @ObservationIgnored private var session = 0

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
            guard SecretStore.save(refreshToken, account: Self.refreshTokenAccount) else {
                throw DropboxError.signInFailed("The sign-in couldn't be saved on this device.")
            }
            session += 1
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
        session += 1
        // Revoke even without a current access token (one is minted from the refresh token), or the device's
        // sign-in would stay valid on Dropbox's side.
        if let client {
            let token = accessToken?.value, refreshToken = SecretStore.load(Self.refreshTokenAccount)
            Task {
                var token = token
                if token == nil, let refreshToken { token = try? await client.refresh(refreshToken).accessToken }
                if let token { await client.revoke(accessToken: token) }
            }
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
        let session = session
        /// Throws if the user connected or disconnected since this sync started.
        func checkSession() throws { if session != self.session { throw CancellationError() } }
        // A conflict means another device uploaded between our download and upload: merge again with its file.
        for attempt in 1...3 {
            do {
                let file = try await authorized(session) { try await client.download(path: Self.path, accessToken: $0) }
                try checkSession()
                // Decoding, merging, and encoding the whole library took about a second on the main thread,
                // which froze scrolling after launch. Only reading and writing the models stays on it.
                let remote = try await Self.offMain { try file.map { try BackupCoding.decode($0.data) } }

                var service = library()
                var local = try service.makeBackup()
                if let remote {
                    while true {
                        let localVersion = version()
                        let merged = try await Self.offMain { [local] in LibrarySync.merge(base: LibrarySync.usableBase(Self.loadBase(), local: local), local: local, remote: remote) }
                        try checkSession()
                        service = library()
                        // A batch (a list import, a refresh) changes models and saves only when it's done, so its
                        // changes made while merging aren't in `local` and applying would delete or undo them.
                        // Save them, which counts as an edit below.
                        if service.context.hasChanges { service.save() }
                        // An edit saved while merging isn't in `local`; applying would undo it, so merge again.
                        guard version() == localVersion else {
                            local = try service.makeBackup()
                            continue
                        }
                        if try service.applySyncedBackup(merged) { local = try service.makeBackup() }
                        break
                    }
                    // The library now holds everything in this file, so the file is the new common ancestor. With
                    // the old base, a retry after a conflict (or the next sync after a failed upload) took what
                    // this merge brought in for edits made here, and overwrote newer edits from other devices.
                    if let file { saveBase(file.data) }
                }
                let snapshotVersion = version()
                let (data, changed) = try await Self.offMain { [local] in
                    let snapshot = LibrarySync.normalized(local)
                    return (try BackupCoding.encoder.encode(snapshot), remote.map { !LibrarySync.sameContent($0, snapshot) } ?? true)
                }

                if changed {
                    try checkSession()
                    try await authorized(session) {
                        try await client.upload(data, path: Self.path, replacing: file?.rev, accessToken: $0)
                    }
                }
                try checkSession()
                saveBase(data)
                syncedVersion = snapshotVersion
                lastSynced = .now
                lastError = nil
                return
            } catch where session != self.session {
                return // Connected or disconnected meanwhile: this sync's results belong to the old session.
            } catch DropboxError.conflict where attempt < 3 {
                continue
            } catch DropboxError.rateLimited where attempt < 3 {
                // "Sync will try again later": wait a little and try again before saying so.
                do { try await Task.sleep(for: .seconds(5 * attempt)) } catch { return }
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

    /// Runs a request with a valid access token, refreshing it first if it expired. The token is checked to
    /// belong to `session`, since getting one can wait on the network.
    private func authorized<T>(_ session: Int, _ request: (String) async throws -> T) async throws -> T {
        func token() async throws -> String {
            let token = try await validAccessToken()
            guard session == self.session else { throw CancellationError() }
            return token
        }
        do {
            return try await request(try await token())
        } catch DropboxError.expiredAccessToken {
            accessToken = nil
            return try await request(try await token())
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
    private nonisolated static var baseURL: URL {
        URL.applicationSupportDirectory.appending(path: "Dropbox Sync Base.json")
    }

    /// Runs pure data work on a background thread.
    private nonisolated static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: work).value
    }

    private nonisolated static func loadBase() -> LibraryBackup? {
        guard let data = try? Data(contentsOf: Self.baseURL) else { return nil }
        return try? BackupCoding.decode(data)
    }

    private func saveBase(_ data: Data) {
        try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        try? data.write(to: Self.baseURL, options: .atomic)
    }
}
