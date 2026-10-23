import AuthenticationServices
import Foundation
import Observation
import SwiftData
import ToWatchCore

/// Keeps the library in sync with a file in the user's Dropbox, so every device signed in to the same
/// Dropbox account sees the same library. See `LibrarySync` for how changes from both sides are merged.
@Observable @MainActor
final class DropboxSync {
    /// In the app's folder: Dropbox ▸ Apps ▸ ToWatchDB.
    static let path = "/ToWatchDB Library.json"
    private static let refreshTokenAccount = "dropbox-refresh-token"

    let client: DropboxClient? = DropboxClient.bundledAppKey.map(DropboxClient.init)

    private(set) var isConnected = false
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

    /// The Dropbox revision the base snapshot matches. While the file is still at it, a sync with no local
    /// changes has nothing to do, and one with changes can merge with the base instead of downloading.
    @ObservationIgnored private var syncedRev: String? = UserDefaults.standard.string(forKey: "dropboxSyncedRev") {
        didSet { UserDefaults.standard.set(syncedRev, forKey: "dropboxSyncedRev") }
    }
    /// Whether a save since the last sync hasn't reached Dropbox, kept across launches. Without it every launch
    /// ran a full sync (snapshotting the whole library) even when nothing had changed. Unknown (an update from a
    /// version without it) counts as yes.
    @ObservationIgnored private var hasUnsyncedEdits = UserDefaults.standard.object(forKey: "dropboxHasUnsyncedEdits") as? Bool ?? true {
        didSet { UserDefaults.standard.set(hasUnsyncedEdits, forKey: "dropboxHasUnsyncedEdits") }
    }
    /// The sign-in couldn't be read when checked (a locked iPhone), so it's checked again before each sync.
    @ObservationIgnored private var isConnectionUnknown = false

    init() {
        checkConnection()
        // Nothing saved since the last sync: the library as launched (version 0) is what Dropbox holds.
        if !hasUnsyncedEdits, syncedRev != nil { syncedVersion = 0 }
    }

    /// Called on every save of the library.
    func noteSave() {
        if !hasUnsyncedEdits { hasUnsyncedEdits = true }
    }

    /// Reads the sign-in again if it couldn't be read before. Called before syncing.
    func checkConnectionIfNeeded() {
        if isConnectionUnknown { checkConnection() }
    }

    private func checkConnection() {
        do {
            isConnected = try SecretStore.read(Self.refreshTokenAccount) != nil
            isConnectionUnknown = false
        } catch {
            isConnectionUnknown = true
        }
    }

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
            syncedRev = nil
            lastSynced = nil
            syncedVersion = nil
            lastError = nil
            isConnectionUnknown = false
            isConnected = true
            let signIn = session
            let email = try? await client.accountEmail(accessToken: tokens.accessToken)
            // Disconnected (or signed in again) meanwhile: the email belongs to a sign-in that's gone.
            if session == signIn { accountEmail = email }
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
        let isForgotten = SecretStore.delete(Self.refreshTokenAccount)
        try? FileManager.default.removeItem(at: Self.baseURL)
        syncedRev = nil
        isConnectionUnknown = false
        accessToken = nil
        accountEmail = nil
        lastSynced = nil
        // Left on the device, the sign-in was found at the next launch and syncing started again.
        lastError = isForgotten ? nil : "The Dropbox sign-in couldn't be removed from this device, so sync may turn back on when the app restarts."
        syncedVersion = nil
        isConnected = false
    }

    // MARK: Syncing

    /// Downloads the file, merges it with the library, and uploads the result if it changed.
    /// `library` must be read fresh after each await; `version` is the library's current save count.
    func sync(library: @escaping () -> LibraryService, version: @escaping () -> Int) async {
        checkConnectionIfNeeded()
        guard isConnected, let client else { return }
        guard !isSyncing else {
            needsAnotherPass = true
            return
        }
        isSyncing = true
        defer { endSync() }
        repeat {
            needsAnotherPass = false
            await syncOnce(client: client, library: library, version: version)
        } while needsAnotherPass && isConnected && lastError == nil
    }

    /// Waits for the sync in progress, if any, without starting one. Returns at once if there is none, and as
    /// soon as the waiting task is cancelled (quitting); the sync itself goes on.
    func waitForSync() async {
        guard isSyncing else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Cancelled before the wait was registered: don't wait at all.
                if isSyncing, !Task.isCancelled { syncWaiters[id] = continuation } else { continuation.resume() }
            }
        } onCancel: {
            Task { @MainActor in self.syncWaiters.removeValue(forKey: id)?.resume() }
        }
    }

    /// Tasks waiting in `waitForSync`, resumed when the sync ends.
    @ObservationIgnored private var syncWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    private func endSync() {
        isSyncing = false
        let waiters = syncWaiters
        syncWaiters = [:]
        for waiter in waiters.values { waiter.resume() }
    }

    private func syncOnce(client: DropboxClient, library: () -> LibraryService, version: () -> Int) async {
        let session = session
        /// Throws if the user connected or disconnected since this sync started.
        func checkSession() throws { if session != self.session { throw CancellationError() } }
        // A conflict means another device uploaded between our download and upload: merge again with its file.
        for attempt in 1...3 {
            do {
                // Most syncs (each time the app comes to the front) find nothing new on either side. Checking the
                // revision skips downloading, decoding and snapshotting the whole library for those.
                let file: DropboxClient.File?
                /// Whether `file` is the base: Dropbox still holds what the last sync uploaded or found.
                var isBase = false
                if attempt == 1, let syncedRev, let base = Self.loadBaseData(),
                   try await authorized(session, { try await client.revision(path: Self.path, accessToken: $0) }) == syncedRev {
                    try checkSession()
                    if syncedVersion == version() {
                        hasUnsyncedEdits = false
                        lastSynced = .now
                        lastError = nil
                        return
                    }
                    file = DropboxClient.File(data: base, rev: syncedRev)
                    isBase = true
                } else {
                    file = try await authorized(session) { try await client.download(path: Self.path, accessToken: $0) }
                }
                try checkSession()
                // Decoding, merging, and encoding the whole library took about a second on the main thread,
                // which froze scrolling after launch. Only reading and writing the models stays on it.
                let remote = try await Self.offMain { try file.map { try BackupCoding.decode($0.data) } }

                var (local, localVersion) = try await snapshot(library: library, version: version)
                // With the file still the base, merging gives back this device's library: skip merging and
                // applying it. Unless the base isn't usable (a lost library), which merges as a first sync.
                if let remote, !(isBase && LibrarySync.usableBase(remote, local: local) != nil) {
                    for pass in 1... {
                        try Task.checkCancellation()
                        if pass > Self.maxPasses { throw LibraryKeptChanging() }
                        // Which titles the merge changes is worked out here too, so applying it writes only those.
                        let (merged, changes) = try await Self.offMain { [local] in
                            let merged = LibrarySync.merge(base: LibrarySync.usableBase(Self.loadBase(), local: local), local: local, remote: remote)
                            return (merged, LibrarySync.changes(from: local, to: merged))
                        }
                        try checkSession()
                        let service = library()
                        // A batch (a list import, a refresh) changes models and saves only when it's done, so its
                        // changes aren't in `local` (a snapshot of what's saved) and applying would delete or
                        // undo them. Save them, which counts as an edit below.
                        if service.context.hasChanges { try service.commit() }
                        // An edit saved since the snapshot isn't in `local`; applying would undo it, so merge again.
                        guard version() == localVersion else {
                            (local, localVersion) = try await snapshot(library: library, version: version)
                            continue
                        }
                        if try service.applySyncedBackup(merged, changes: changes) {
                            (local, localVersion) = try await snapshot(library: library, version: version)
                        }
                        break
                    }
                    // The library now holds everything in this file, so the file is the new common ancestor. With
                    // the old base, a retry after a conflict (or the next sync after a failed upload) took what
                    // this merge brought in for edits made here, and overwrote newer edits from other devices.
                    try checkSession()
                    if let file { saveBase(file.data, rev: file.rev) }
                }
                let snapshotVersion = localVersion
                let (data, changed) = try await Self.offMain { [local] in
                    (try BackupCoding.compressed(BackupCoding.compactEncoder.encode(local)),
                     remote.map { !LibrarySync.sameContent($0, local) } ?? true)
                }

                var rev = file?.rev
                if changed {
                    try checkSession()
                    rev = try await authorized(session) {
                        try await client.upload(data, path: Self.path, replacing: file?.rev, accessToken: $0)
                    }
                }
                try checkSession()
                saveBase(data, rev: rev)
                syncedVersion = snapshotVersion
                if snapshotVersion == version() { hasUnsyncedEdits = false }
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
            } catch DropboxError.secretsUnavailable {
                lastError = DropboxError.secretsUnavailable.localizedDescription
                return
            } catch DropboxError.signedOut {
                disconnect()
                lastError = DropboxError.signedOut.localizedDescription
                return
            } catch is CancellationError {
                return
            } catch is LibraryKeptChanging {
                // Not again right away, which would be the same race: the edits stay unsynced (`syncedVersion`
                // is behind), so the next save, activation, or quit syncs them.
                needsAnotherPass = false
                return
            } catch {
                lastError = error.localizedDescription
                return
            }
        }
    }

    /// The library as saved, with its version. Snapshotting walks every title and episode, so it runs off the
    /// main thread with a context of its own. A save landing meanwhile could leave it half old, half new, so
    /// it's taken again then.
    private func snapshot(library: () -> LibraryService, version: () -> Int) async throws -> (LibraryBackup, Int) {
        for _ in 1...Self.maxPasses {
            // Saves can keep landing (a list import), and quitting waits for the sync only so long.
            try Task.checkCancellation()
            let snapshotVersion = version()
            let container = library().context.container
            let backup = try await Self.offMain { try LibraryService.makeBackup(in: ModelContext(container)) }
            if version() == snapshotVersion { return (backup, snapshotVersion) }
        }
        throw LibraryKeptChanging()
    }

    /// How many times a snapshot or merge starts over because a save landed meanwhile. Each pass reads the whole
    /// library (about 2 s for 300 shows), and nothing else cancels a sync: edits saved faster than that kept it
    /// going, with the launch refresh waiting on it.
    private static let maxPasses = 5

    /// Saves kept landing during a sync. It stops without an error, leaving them for the next sync.
    private struct LibraryKeptChanging: Error {}

    /// Runs a request with a valid access token, refreshing it first if it expired. The token is checked to
    /// belong to `session`, since getting one can wait on the network.
    @discardableResult
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
        let session = session
        let refreshToken: String?
        do { refreshToken = try SecretStore.read(Self.refreshTokenAccount) } catch { throw DropboxError.secretsUnavailable }
        guard let client, let refreshToken else { throw DropboxError.signedOut }
        let tokens = try await client.refresh(refreshToken)
        // Connecting or disconnecting meanwhile: this token is for the old sign-in, and caching it would let the
        // next sync upload to that account.
        guard session == self.session else { throw CancellationError() }
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

    /// Makes the next sync a first sync, which brings the file's library in rather than merging against the last
    /// sync: for a library that was lost, every title would look deleted here and be deleted on every device.
    nonisolated static func forgetBase() {
        try? FileManager.default.removeItem(at: Self.baseURL)
        UserDefaults.standard.removeObject(forKey: "dropboxSyncedRev")
    }

    private nonisolated static func loadBaseData() -> Data? { try? Data(contentsOf: Self.baseURL) }

    private nonisolated static func loadBase() -> LibraryBackup? {
        loadBaseData().flatMap { try? BackupCoding.decode($0) }
    }

    /// `rev` is the Dropbox revision whose content `data` matches, if known.
    private func saveBase(_ data: Data, rev: String?) {
        try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        do {
            try data.write(to: Self.baseURL, options: .atomic)
            syncedRev = rev
        } catch {
            syncedRev = nil
        }
    }
}
