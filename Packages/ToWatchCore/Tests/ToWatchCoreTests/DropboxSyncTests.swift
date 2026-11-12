import Foundation
import SwiftData
import Synchronization
import Testing
@testable import ToWatchCore

// `DropboxSync` driven against a fake Dropbox: one file with a revision, conditional uploads, and the token endpoint.

/// What the fake Dropbox holds and has been asked, shared by every session in a test (the suite runs one at a time).
private final class FakeDropboxState: Sendable {
    struct Contents {
        var file: (data: Data, rev: Int)?
        var requests: [String] = []
        var refreshIsRevoked = false
        /// Another device uploads this just before the next upload is answered, which then conflicts.
        var uploadFirst: Data?
        /// A download waits until this is false.
        var holdsDownloads = false
        var isHoldingDownload = false
    }

    let contents = Mutex(Contents())

    func count(_ endpoint: String) -> Int { contents.withLock { $0.requests.filter { $0 == endpoint }.count } }
}

private let fakeDropbox = FakeDropboxState()

private final class FakeDropboxProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let endpoint = request.url?.path() ?? ""
        let argument = request.value(forHTTPHeaderField: "Dropbox-API-Arg").flatMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        if endpoint == "/2/files/download" {
            fakeDropbox.contents.withLock { $0.isHoldingDownload = $0.holdsDownloads }
            while fakeDropbox.contents.withLock({ $0.holdsDownloads }) { Thread.sleep(forTimeInterval: 0.01) }
        }
        let (status, data, headers) = fakeDropbox.contents.withLock { state -> (Int, Data, [String: String]) in
            state.requests.append(endpoint)
            let notFound = Data(#"{"error_summary":"path/not_found/.."}"#.utf8)
            switch endpoint {
            case "/oauth2/token":
                if state.refreshIsRevoked { return (400, Data(#"{"error":"invalid_grant"}"#.utf8), [:]) }
                return (200, Data(#"{"access_token":"access","expires_in":14400}"#.utf8), [:])
            case "/2/files/get_metadata":
                guard let file = state.file else { return (409, notFound, [:]) }
                return (200, Data(#"{"rev":"\#(file.rev)"}"#.utf8), [:])
            case "/2/files/download":
                guard let file = state.file else { return (409, notFound, [:]) }
                return (200, file.data, ["Dropbox-API-Result": #"{"rev":"\#(file.rev)"}"#])
            case "/2/files/upload":
                if let first = state.uploadFirst {
                    state.file = (first, (state.file?.rev ?? 0) + 1)
                    state.uploadFirst = nil
                }
                let mode = argument?["mode"]
                let replacing = (mode as? [String: Any])?["update"] as? String
                let matches = replacing.map { $0 == state.file.map { String($0.rev) } } ?? (state.file == nil)
                guard matches else { return (409, Data(#"{"error_summary":"path/conflict/file/.."}"#.utf8), [:]) }
                let rev = (state.file?.rev ?? 0) + 1
                state.file = (body, rev)
                return (200, Data(#"{"rev":"\#(rev)"}"#.utf8), [:])
            default:
                return (200, Data("{}".utf8), [:])
            }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// A device's saved Dropbox sign-in.
private final class TokenBox: Sendable {
    let value = Mutex<String?>("refresh")
}

/// A device: its own library, sync state, and sign-in, against the shared fake Dropbox.
@MainActor
private final class Device {
    let container: ModelContainer
    let sync: DropboxSync
    let token = TokenBox()
    /// Where this device copies its library before a sync deletes a large part of it.
    let copies: URL
    private(set) var version = 0
    private var observer: (any NSObjectProtocol)?

    var library: LibraryService { LibraryService(context: container.mainContext, client: nil) }

    init() throws {
        container = try ModelContainer(for: ToWatchSchema.current, migrationPlan: ToWatchMigrationPlan.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container.mainContext.autosaveEnabled = false
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeDropboxProtocol.self]
        let token = token
        let vault = DropboxSync.Vault(read: { token.value.withLock { $0 } },
                                      save: { value in token.value.withLock { $0 = value }; return true },
                                      delete: { token.value.withLock { $0 = nil }; return true })
        let folder = URL.temporaryDirectory.appending(path: "dropbox-sync-\(UUID().uuidString)")
        copies = folder.appending(path: "Copies")
        sync = DropboxSync(client: DropboxClient(appKey: "test", session: URLSession(configuration: configuration)),
                           vault: vault, defaults: UserDefaults(suiteName: UUID().uuidString)!,
                           baseURL: folder.appending(path: "Base.json"), copiesURL: copies)
        observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: container.mainContext,
                                                          queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.version += 1 }
        }
    }

    func runSync() async { await sync.sync(library: { self.library }, version: { self.version }) }

    @discardableResult
    func addMovie(_ id: Int, _ title: String) -> Movie {
        let movie = Movie(tmdbID: id, title: title)
        container.mainContext.insert(movie)
        library.save()
        return movie
    }

    func movie(_ id: Int) -> Movie? { library.movie(tmdbID: id) }

    var movieIDs: [Int] {
        ((try? container.mainContext.fetch(FetchDescriptor<Movie>())) ?? []).map(\.tmdbID).sorted()
    }
}

private func reset() {
    fakeDropbox.contents.withLock { $0 = .init() }
}

private func fileContents() throws -> LibraryBackup {
    let data = try #require(fakeDropbox.contents.withLock { $0.file?.data })
    return try BackupCoding.decode(data)
}

@Suite(.serialized)
@MainActor
struct DropboxSyncTests {
    @Test func firstSyncUploadsThenAnUnchangedSyncOnlyChecksTheRevision() async throws {
        reset()
        let mac = try Device()
        mac.addMovie(1, "Arrival")
        await mac.runSync()
        #expect(mac.sync.lastError == nil)
        #expect(try fileContents().movies.map(\.tmdbID) == [1])
        #expect(fakeDropbox.count("/2/files/upload") == 1)

        await mac.runSync()
        #expect(fakeDropbox.count("/2/files/get_metadata") == 1)
        #expect(fakeDropbox.count("/2/files/download") == 1) // Only the first sync's, which found no file.
        #expect(fakeDropbox.count("/2/files/upload") == 1)
        #expect(mac.sync.syncedVersion == mac.version)
    }

    @Test func aRefreshOnlySaveNeedsNoSyncAndRidesAlongWithTheNextEdit() async throws {
        reset()
        let mac = try Device()
        let movie = mac.addMovie(1, "Arrival")
        await mac.runSync()
        movie.overview = "Refreshed from TMDB"
        mac.library.save()
        mac.sync.noteSave(version: mac.version, refreshOnly: true)
        #expect(mac.sync.syncedVersion == mac.version)
        await mac.runSync()
        #expect(fakeDropbox.count("/2/files/download") == 1) // Only the first sync's, which found no file.
        #expect(fakeDropbox.count("/2/files/upload") == 1)

        mac.library.setWatched(movie, true, on: Date(timeIntervalSince1970: 1_700_000_000))
        mac.sync.noteSave(version: mac.version)
        await mac.runSync()
        #expect(fakeDropbox.count("/2/files/upload") == 2)
        #expect(try fileContents().movies.first?.overview == "Refreshed from TMDB")
    }

    @Test func aRefreshOnlySaveAfterUnsyncedEditsStillSyncs() async throws {
        reset()
        let mac = try Device()
        let movie = mac.addMovie(1, "Arrival")
        await mac.runSync()
        mac.library.setWatched(movie, true, on: Date(timeIntervalSince1970: 1_700_000_000))
        mac.sync.noteSave(version: mac.version)
        movie.overview = "Refreshed from TMDB"
        mac.library.save()
        mac.sync.noteSave(version: mac.version, refreshOnly: true)
        #expect(mac.sync.syncedVersion != mac.version)
        await mac.runSync()
        #expect(fakeDropbox.count("/2/files/upload") == 2)
        #expect(try fileContents().movies.first?.isWatched == true)
    }

    @Test func editsReachTheOtherDevice() async throws {
        reset()
        let mac = try Device(), phone = try Device()
        mac.addMovie(1, "Arrival")
        await mac.runSync()
        await phone.runSync()
        let onPhone = try #require(phone.movie(1))
        phone.library.setWatched(onPhone, true, on: Date(timeIntervalSince1970: 1_700_000_000))
        await phone.runSync()
        await mac.runSync()
        #expect(mac.movie(1)?.isWatched == true)
        #expect(mac.sync.lastError == nil && phone.sync.lastError == nil)
    }

    @Test func aConflictMergesAgainWithTheNewerFile() async throws {
        reset()
        let mac = try Device(), phone = try Device()
        mac.addMovie(1, "Arrival")
        await mac.runSync()
        await phone.runSync()
        // The phone adds a movie and its upload lands just before the Mac's, which then conflicts.
        phone.addMovie(2, "Dune")
        let phoneFile = try BackupCoding.compressed(BackupCoding.compactEncoder.encode(phone.library.makeBackup()))
        mac.library.setWatched(try #require(mac.movie(1)), true, on: Date(timeIntervalSince1970: 1_700_000_000))
        fakeDropbox.contents.withLock { $0.uploadFirst = phoneFile }
        await mac.runSync()

        #expect(mac.sync.lastError == nil)
        #expect(fakeDropbox.count("/2/files/upload") == 3) // The first sync's, the one turned down, the merged one.
        let file = try fileContents()
        #expect(Set(file.movies.map(\.tmdbID)) == [1, 2])
        #expect(file.movies.first { $0.tmdbID == 1 }?.isWatched == true)
        #expect(mac.movie(2) != nil)
    }

    @Test func aRevokedSignInSignsTheDeviceOut() async throws {
        reset()
        fakeDropbox.contents.withLock { $0.refreshIsRevoked = true }
        let mac = try Device()
        mac.addMovie(1, "Arrival")
        await mac.runSync()
        #expect(!mac.sync.isConnected)
        #expect(mac.sync.lastError == DropboxError.signedOut.localizedDescription)
        #expect(mac.token.value.withLock { $0 } == nil)
        #expect(fakeDropbox.count("/2/files/upload") == 0)
    }

    @Test func disconnectingMidSyncUploadsNothing() async throws {
        reset()
        let mac = try Device()
        mac.addMovie(1, "Arrival")
        await mac.runSync() // Uploads, so the next sync downloads.
        mac.addMovie(2, "Dune")
        fakeDropbox.contents.withLock { $0.file?.rev += 1; $0.holdsDownloads = true } // Changed elsewhere.
        let sync = Task { await mac.runSync() }
        while !fakeDropbox.contents.withLock({ $0.isHoldingDownload }) { try await Task.sleep(for: .milliseconds(10)) }
        mac.sync.disconnect()
        fakeDropbox.contents.withLock { $0.holdsDownloads = false }
        await sync.value
        #expect(fakeDropbox.count("/2/files/upload") == 1)
        #expect(!mac.sync.isConnected && mac.sync.lastError == nil)
    }

    @Test func theLibraryIsCopiedBeforeASyncDeletesALargePartOfIt() async throws {
        reset()
        let mac = try Device(), phone = try Device()
        for id in 1...12 { mac.addMovie(id, "Movie \(id)") }
        await mac.runSync()
        await phone.runSync()
        #expect(phone.movieIDs.count == 12)

        // One title deleted elsewhere: no copy.
        mac.library.delete(try #require(mac.movie(12)))
        await mac.runSync()
        await phone.runSync()
        #expect(phone.movieIDs.count == 11)
        #expect(LibraryCopies.all(in: phone.copies).isEmpty)

        // Nearly all of them: the phone keeps what it had, and it merges back.
        for id in 1...10 { mac.library.delete(try #require(mac.movie(id))) }
        await mac.runSync()
        await phone.runSync()
        #expect(phone.sync.lastError == nil)
        #expect(phone.movieIDs == [11])
        let copy = try #require(LibraryCopies.all(in: phone.copies).first)
        #expect(LibraryCopies.all(in: phone.copies).count == 1)
        try phone.library.importBackup(LibraryCopies.load(copy))
        #expect(phone.movieIDs.count == 11)
    }

    @Test func onlyTheLastLibraryCopiesAreKept() throws {
        let mac = try Device()
        for day in 1...5 {
            mac.addMovie(day, "Movie \(day)")
            try LibraryCopies.save(mac.library.makeBackup(), in: mac.copies, now: Date(timeIntervalSince1970: Double(day) * 86400))
        }
        let copies = LibraryCopies.all(in: mac.copies)
        #expect(try copies.map { try LibraryCopies.load($0).movies.count } == [5, 4, 3])
        #expect(!LibraryCopies.isLargeDeletion(9, of: 10))
        #expect(!LibraryCopies.isLargeDeletion(20, of: 100))
        #expect(LibraryCopies.isLargeDeletion(25, of: 100))
    }

    @Test func aFirstSyncLargerThanASliceAppliesWhole() async throws {
        reset()
        let mac = try Device(), phone = try Device()
        // Six slices of an apply: one save each must not read as an edit landing, or the sync starts over after
        // each slice and gives up after five passes.
        let count = LibraryService.sliceSize * 5 + 200
        for id in 1...count { phone.container.mainContext.insert(Movie(tmdbID: id, title: "Movie \(id)")) }
        phone.library.save()
        await phone.runSync()
        mac.addMovie(5000, "Only on the Mac")
        let before = mac.version
        await mac.runSync()
        #expect(mac.sync.lastError == nil)
        #expect(mac.version - before == 6, "applied in six saves")
        #expect(try mac.container.mainContext.fetchCount(FetchDescriptor<Movie>()) == count + 1)
        #expect(try fileContents().movies.count == count + 1)
        #expect(mac.sync.syncedVersion == mac.version)
    }

    @Test func savesThatKeepLandingEndTheSyncQuietly() async throws {
        reset()
        let mac = try Device()
        mac.addMovie(1, "Arrival")
        var calls = 0
        // Every read of the version is newer than the last, as if saves landed during each snapshot.
        await mac.sync.sync(library: { mac.library }, version: {
            calls += 1
            return calls
        })
        #expect(mac.sync.lastError == nil)
        #expect(fakeDropbox.count("/2/files/upload") == 0)
        #expect(!mac.sync.isSyncing)
    }
}
