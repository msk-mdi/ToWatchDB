import Foundation

/// Copies of the library kept on this device before a sync deletes a large part of it. A sync applies what the
/// other devices did, deletions included: a library emptied by mistake on one of them took the titles away on
/// every device, with nothing left to bring them back from.
public enum LibraryCopies {
    public struct Copy: Identifiable, Sendable, Hashable {
        public let url: URL
        /// When the copy was made.
        public let date: Date
        public var id: URL { url }
    }

    /// Where the app keeps them.
    public static var defaultFolder: URL {
        URL.applicationSupportDirectory.appending(path: "Library Copies")
    }

    /// How many are kept; a new one replaces the oldest. Each is the whole library.
    static let limit = 3

    /// Whether deleting `deleted` of the library's `total` titles is worth a copy first: a quarter of it or more,
    /// and not the handful that makes a quarter of a small library.
    public static func isLargeDeletion(_ deleted: Int, of total: Int) -> Bool {
        deleted >= 10 && deleted * 4 >= total
    }

    /// How many of `local`'s titles `merged` no longer has.
    public static func deletedTitles(from local: LibraryBackup, to merged: LibraryBackup) -> Int {
        let movies = Set(merged.movies.map(\.tmdbID)), shows = Set(merged.shows.map(\.tmdbID))
        return local.movies.count { !movies.contains($0.tmdbID) } + local.shows.count { !shows.contains($0.tmdbID) }
    }

    /// Writes `backup` as a new copy, then removes the oldest beyond `limit`.
    @discardableResult
    public static func save(_ backup: LibraryBackup, in folder: URL = defaultFolder, now: Date = .now) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "Library \(now.ISO8601Format().replacing(":", with: ".")).json")
        try BackupCoding.compressed(BackupCoding.compactEncoder.encode(backup)).write(to: url, options: .atomic)
        try? manager.setAttributes([.modificationDate: now], ofItemAtPath: url.path(percentEncoded: false))
        for old in all(in: folder).dropFirst(limit) { try? manager.removeItem(at: old.url) }
        return url
    }

    /// The copies kept, newest first.
    public static func all(in folder: URL = defaultFolder) -> [Copy] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "json" }
            .map { Copy(url: $0, date: (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
            .sorted { ($0.date, $0.url.lastPathComponent) > ($1.date, $1.url.lastPathComponent) }
    }

    /// The library a copy holds, to merge back with `LibraryService.importBackupInSlices`.
    public static func load(_ copy: Copy) throws -> LibraryBackup {
        try BackupCoding.decode(Data(contentsOf: copy.url))
    }
}
