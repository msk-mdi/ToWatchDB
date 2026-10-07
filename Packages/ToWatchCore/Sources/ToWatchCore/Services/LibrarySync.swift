import Foundation
import SwiftData

// Two-way sync through a shared backup file (the app keeps it in Dropbox).
//
// Each device remembers the snapshot it last synced: the base. A sync merges three snapshots: the base, this
// device's library, and the shared file. A value changed here since the base wins; otherwise the shared file's
// value is taken. Something in the base but missing on one side was deleted there, so it's deleted on the other
// too (a deletion beats an edit made elsewhere). Without a base (a device's first sync) nothing is deleted and
// the two sides combine like a backup import: watched, backlog, and favorite stay set if set on either side.
//
// Only what the user owns is merged: watch state, ratings, flags, notes, and collections. TMDB metadata is
// kept from this device (it refreshes from TMDB anyway); titles new to this device take the file's metadata.
// IMDb ratings are the exception: the more recently fetched one wins, so devices don't each ask IMDb.

public enum LibrarySync {
    /// The merged library: apply it here with `applySyncedBackup`, then upload what results.
    public static func merge(base: LibraryBackup?, local: LibraryBackup, remote: LibraryBackup) -> LibraryBackup {
        // Dates in a file have whole seconds; round-trip this device's library so unchanged dates compare equal.
        let (base, local, remote) = matchingTags(base.map(normalized), normalized(local), normalized(remote))

        var merged = local
        merged.spaces = keyed(base?.spaces, local.spaces, remote.spaces, key: \.uuid) { m in
            var space = m.local
            space.name = m.pick(\.name)
            space.symbolName = m.pick(\.symbolName)
            space.colorName = m.pick(\.colorName)
            space.createdAt = min(m.local.createdAt, m.remote.createdAt)
            return space
        }
        merged.tags = keyed(base?.tags, local.tags, remote.tags, key: \.uuid) { m in
            var tag = m.local
            tag.name = m.pick(\.name)
            tag.colorName = m.pick(\.colorName)
            tag.createdAt = min(m.local.createdAt, m.remote.createdAt)
            return tag
        }
        let spaceIDs = Set(merged.spaces.map(\.uuid))
        let tagIDs = Set(merged.tags.map(\.uuid))

        merged.smartLists = keyed(base?.smartLists, local.smartLists, remote.smartLists, key: \.uuid) { m in
            var list = m.local
            list.name = m.pick(\.name)
            list.symbolName = m.pick(\.symbolName)
            list.colorName = m.pick(\.colorName)
            list.rules = m.pick(\.rules)
            list.createdAt = min(m.local.createdAt, m.remote.createdAt)
            return list
        }.map { list in
            // A space or tag deleted on either side drops out of the rules, as when it's deleted in the app.
            var list = list
            list.rules.spaceIDs.formIntersection(spaceIDs)
            list.rules.tagIDs.formIntersection(tagIDs)
            return list
        }

        merged.movies = keyed(base?.movies, local.movies, remote.movies, key: \.tmdbID) { m in
            var movie = m.local
            let watch = m.pick(WatchState.init) { $0.combined(with: $1) }
            movie.isWatched = watch.isWatched
            movie.watchedDate = watch.date
            movie.userRating = m.pick(\.userRating) { $0 ?? $1 }
            movie.isInBacklog = m.pick(\.isInBacklog) { $0 || $1 } && !movie.isWatched
            movie.isFavorite = m.pick(\.isFavorite) { $0 || $1 }
            movie.addedDate = min(m.local.addedDate, m.remote.addedDate)
            movie.notes = notes(m.base?.notes, m.local.notes, m.remote.notes)
            movie.spaceIDs = m.set(\.spaceIDs)
            movie.tagIDs = m.set(\.tagIDs)
            movie.takeNewerIMDbRating(from: m.remote)
            return movie
        }.map { movie in
            var movie = movie
            movie.spaceIDs.removeAll { !spaceIDs.contains($0) }
            movie.tagIDs.removeAll { !tagIDs.contains($0) }
            return movie
        }

        merged.shows = keyed(base?.shows, local.shows, remote.shows, key: \.tmdbID) { m in
            var show = m.local
            show.userRating = m.pick(\.userRating) { $0 ?? $1 }
            show.isInBacklog = m.pick(\.isInBacklog) { $0 || $1 }
            show.isFavorite = m.pick(\.isFavorite) { $0 || $1 }
            show.isAbandoned = m.pick(\.isAbandoned) { $0 || $1 }
            show.addedDate = min(m.local.addedDate, m.remote.addedDate)
            show.notes = notes(m.base?.notes, m.local.notes, m.remote.notes)
            show.spaceIDs = m.set(\.spaceIDs)
            show.tagIDs = m.set(\.tagIDs)
            show.seasons = seasons(m)
            show.takeNewerIMDbRating(from: m.remote)
            return show
        }.map { show in
            var show = show
            show.spaceIDs.removeAll { !spaceIDs.contains($0) }
            show.tagIDs.removeAll { !tagIDs.contains($0) }
            return show
        }
        return merged
    }

    /// The last sync's snapshot to merge against, or `nil` to merge as a first sync. An empty library whose last
    /// sync had several titles was lost or recreated (a reset store, a failed migration), not emptied by hand:
    /// against the base, every title would look deleted here and the merge would empty the file on every device.
    /// As a first sync, it gets the file's library back instead.
    public static func usableBase(_ base: LibraryBackup?, local: LibraryBackup) -> LibraryBackup? {
        guard let base else { return nil }
        let isEmpty = local.titleCount == 0 && local.spaces.isEmpty && local.tags.isEmpty && local.smartLists.isEmpty
        return isEmpty && base.titleCount >= 5 ? nil : base
    }

    /// The backup as it reads back from a file: dates to the whole second.
    public static func normalized(_ backup: LibraryBackup) -> LibraryBackup {
        guard let data = try? BackupCoding.compactEncoder.encode(backup),
              let decoded = try? BackupCoding.decoder.decode(LibraryBackup.self, from: data) else { return backup }
        return decoded
    }

    /// Whether two snapshots hold the same library for the user: the same titles and collections, and the same
    /// watch data, ratings, notes, and memberships. TMDB and IMDb details are left out: each device refreshes them
    /// at its own times and a merge keeps its own, so comparing them made devices re-upload on every sync.
    /// Dates are written to the whole second, so the snapshots don't need normalizing first.
    public static func sameContent(_ a: LibraryBackup, _ b: LibraryBackup) -> Bool {
        let a = try? BackupCoding.compactEncoder.encode(UserContent(a))
        return a != nil && a == (try? BackupCoding.compactEncoder.encode(UserContent(b)))
    }

    /// The parts of a snapshot the user owns, in a stable order.
    private struct UserContent: Encodable {
        struct Movie: Encodable {
            let tmdbID: Int, addedDate: Date, isWatched: Bool, watchedDate: Date?, userRating: Double?
            let isInBacklog: Bool, isFavorite: Bool, notes: [LibraryBackup.NoteRecord], spaceIDs: [UUID], tagIDs: [UUID]
        }
        struct Show: Encodable {
            let tmdbID: Int, addedDate: Date, userRating: Double?, isInBacklog: Bool, isFavorite: Bool, isAbandoned: Bool
            let notes: [LibraryBackup.NoteRecord], spaceIDs: [UUID], tagIDs: [UUID], episodes: [Episode]
        }
        /// Only episodes with something of the user's: new episodes from a refresh aren't a change.
        struct Episode: Encodable {
            let season: Int, episode: Int, isWatched: Bool, watchedDate: Date?, userRating: Double?
            let notes: [LibraryBackup.NoteRecord]
        }

        let movies: [Movie], shows: [Show]
        let spaces: [LibraryBackup.SpaceRecord], tags: [LibraryBackup.TagRecord], smartLists: [LibraryBackup.SmartListRecord]

        init(_ backup: LibraryBackup) {
            func sorted(_ ids: [UUID]) -> [UUID] { ids.sorted { $0.uuidString < $1.uuidString } }
            movies = backup.movies.sorted { $0.tmdbID < $1.tmdbID }.map {
                Movie(tmdbID: $0.tmdbID, addedDate: $0.addedDate, isWatched: $0.isWatched, watchedDate: $0.watchedDate,
                      userRating: $0.userRating, isInBacklog: $0.isInBacklog, isFavorite: $0.isFavorite, notes: $0.notes,
                      spaceIDs: sorted($0.spaceIDs), tagIDs: sorted($0.tagIDs))
            }
            shows = backup.shows.sorted { $0.tmdbID < $1.tmdbID }.map { show in
                let episodes = show.seasons.flatMap { season in
                    season.episodes.compactMap { episode -> Episode? in
                        guard episode.isWatched || episode.userRating != nil || !episode.notes.isEmpty else { return nil }
                        return Episode(season: season.seasonNumber, episode: episode.episodeNumber, isWatched: episode.isWatched,
                                       watchedDate: episode.watchedDate, userRating: episode.userRating, notes: episode.notes)
                    }
                }
                return Show(tmdbID: show.tmdbID, addedDate: show.addedDate, userRating: show.userRating,
                            isInBacklog: show.isInBacklog, isFavorite: show.isFavorite, isAbandoned: show.isAbandoned,
                            notes: show.notes, spaceIDs: sorted(show.spaceIDs), tagIDs: sorted(show.tagIDs),
                            episodes: episodes.sorted { ($0.season, $0.episode) < ($1.season, $1.episode) })
            }
            spaces = backup.spaces.sorted { $0.uuid.uuidString < $1.uuid.uuidString }
            tags = backup.tags.sorted { $0.uuid.uuidString < $1.uuid.uuidString }
            smartLists = backup.smartLists.sorted { $0.uuid.uuidString < $1.uuid.uuidString }
        }
    }

    // MARK: Merging

    /// One record as it was at the last sync (nil if it's new or this is the first sync), here, and in the file.
    struct Versions<Record> {
        let base: Record?
        let local: Record
        let remote: Record

        /// This device's value if it changed since the last sync, otherwise the file's.
        /// Without a base, `firstSync` combines the two.
        func pick<T: Equatable>(_ field: (Record) -> T, firstSync: (T, T) -> T = { local, _ in local }) -> T {
            let local = field(local), remote = field(remote)
            guard let base else { return firstSync(local, remote) }
            return local != field(base) ? local : remote
        }

        /// Members kept on both sides, plus those either side added since the last sync.
        func set<E: Hashable>(_ field: (Record) -> [E]) -> [E] {
            let base = Set(base.map(field) ?? [])
            let local = field(local), remote = field(remote)
            let localSet = Set(local), remoteSet = Set(remote)
            var result = local.filter { remoteSet.contains($0) || !base.contains($0) }
            result += remote.filter { !localSet.contains($0) && !base.contains($0) }
            return result
        }
    }

    /// Merges two keyed lists. Keeps this device's order, then appends what's new in the file.
    static func keyed<K: Hashable, V>(_ base: [V]?, _ local: [V], _ remote: [V], key: (V) -> K,
                                      merge: (Versions<V>) -> V) -> [V] {
        let baseByKey = base.map { Dictionary($0.map { (key($0), $0) }) { first, _ in first } }
        let remoteByKey = Dictionary(remote.map { (key($0), $0) }) { first, _ in first }
        var seen = Set<K>()
        var result: [V] = []
        for local in local {
            let k = key(local)
            guard seen.insert(k).inserted else { continue }
            if let remote = remoteByKey[k] {
                result.append(merge(Versions(base: baseByKey?[k], local: local, remote: remote)))
            } else if baseByKey?[k] == nil {
                result.append(local) // Added here since the last sync.
            } // Otherwise it was deleted on another device.
        }
        for remote in remote {
            let k = key(remote)
            // In the base but not here: deleted on this device.
            guard baseByKey?[k] == nil, seen.insert(k).inserted else { continue }
            result.append(remote)
        }
        return result
    }

    /// Notes are identified by creation time; an edit changes the text and `updatedAt`.
    static func notes(_ base: [LibraryBackup.NoteRecord]?, _ local: [LibraryBackup.NoteRecord],
                      _ remote: [LibraryBackup.NoteRecord]) -> [LibraryBackup.NoteRecord] {
        keyed(base, local, remote, key: { noteKey($0.createdAt) }) { m in
            m.pick({ $0 }) { local, remote in remote.updatedAt > local.updatedAt ? remote : local }
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    static func noteKey(_ createdAt: Date) -> Int { Int(createdAt.timeIntervalSince1970.rounded(.down)) }

    /// Seasons and episodes are TMDB metadata, so one missing here isn't a deletion: the file's is kept if it
    /// holds user data. One without any isn't taken: a refresh here removed it because TMDB dropped it, and
    /// taking it back brought back the phantom episodes the removal was for. Each device's own refresh adds
    /// the real new ones. Episodes on both sides merge their watch state, rating, and notes.
    private static func seasons(_ show: Versions<LibraryBackup.ShowRecord>) -> [LibraryBackup.SeasonRecord] {
        typealias EpisodeKey = [Int]
        func episodes(_ record: LibraryBackup.ShowRecord?) -> [EpisodeKey: LibraryBackup.EpisodeRecord] {
            var result: [EpisodeKey: LibraryBackup.EpisodeRecord] = [:]
            for season in record?.seasons ?? [] {
                for episode in season.episodes { result[[season.seasonNumber, episode.episodeNumber]] = episode }
            }
            return result
        }
        let baseEpisodes = show.base.map { episodes($0) }
        let remoteEpisodes = episodes(show.remote)

        var seasons = show.local.seasons.map { season in
            var season = season
            season.episodes = season.episodes.map { local in
                let key = [season.seasonNumber, local.episodeNumber]
                guard let remote = remoteEpisodes[key] else { return local }
                let m = Versions(base: baseEpisodes?[key], local: local, remote: remote)
                var episode = local
                let watch = m.pick(WatchState.init) { $0.combined(with: $1) }
                episode.isWatched = watch.isWatched
                episode.watchedDate = watch.date
                episode.userRating = m.pick(\.userRating) { $0 ?? $1 }
                episode.notes = notes(m.base?.notes, local.notes, remote.notes)
                return episode
            }
            return season
        }
        func hasUserData(_ episode: LibraryBackup.EpisodeRecord) -> Bool {
            episode.isWatched || episode.userRating != nil || !episode.notes.isEmpty
        }
        for remoteSeason in show.remote.seasons {
            if let index = seasons.firstIndex(where: { $0.seasonNumber == remoteSeason.seasonNumber }) {
                let present = Set(seasons[index].episodes.map(\.episodeNumber))
                let added = remoteSeason.episodes.filter { !present.contains($0.episodeNumber) && hasUserData($0) }
                guard !added.isEmpty else { continue }
                seasons[index].episodes += added
                seasons[index].episodes.sort { $0.episodeNumber < $1.episodeNumber }
            } else if remoteSeason.episodes.contains(where: hasUserData) {
                var season = remoteSeason
                season.episodes = season.episodes.filter(hasUserData)
                seasons.append(season)
            }
        }
        return seasons.sorted { $0.seasonNumber < $1.seasonNumber }
    }

    /// Two devices can each create a tag with the same name. Tags are matched by name in the app, so they
    /// become one tag rather than twins. Both sides settle on the smaller ID, so every device picks the same one.
    /// The base is renamed too: otherwise the device whose ID was dropped saw its own tag as new, kept its own
    /// name over the file's, and the devices took an extra round of uploads to agree.
    private static func matchingTags(_ base: LibraryBackup?, _ local: LibraryBackup,
                                     _ remote: LibraryBackup) -> (LibraryBackup?, LibraryBackup, LibraryBackup) {
        var replacements: [UUID: UUID] = [:]
        for remoteTag in remote.tags where !local.tags.contains(where: { $0.uuid == remoteTag.uuid }) {
            guard let localTag = local.tags.first(where: { $0.name.localizedCaseInsensitiveCompare(remoteTag.name) == .orderedSame }),
                  !remote.tags.contains(where: { $0.uuid == localTag.uuid }) else { continue }
            let kept = min(localTag.uuid.uuidString, remoteTag.uuid.uuidString) == localTag.uuid.uuidString ? localTag.uuid : remoteTag.uuid
            replacements[localTag.uuid] = kept
            replacements[remoteTag.uuid] = kept
        }
        guard !replacements.isEmpty else { return (base, local, remote) }
        func replacingTags(in backup: LibraryBackup) -> LibraryBackup {
            func replaced(_ id: UUID) -> UUID { replacements[id] ?? id }
            var backup = backup
            for index in backup.tags.indices { backup.tags[index].uuid = replaced(backup.tags[index].uuid) }
            for index in backup.movies.indices { backup.movies[index].tagIDs = backup.movies[index].tagIDs.map(replaced) }
            for index in backup.shows.indices { backup.shows[index].tagIDs = backup.shows[index].tagIDs.map(replaced) }
            for index in backup.smartLists.indices {
                backup.smartLists[index].rules.tagIDs = Set(backup.smartLists[index].rules.tagIDs.map(replaced))
            }
            return backup
        }
        return (base.map(replacingTags), replacingTags(in: local), replacingTags(in: remote))
    }

    /// Watched and its date change together.
    private struct WatchState: Equatable {
        var isWatched: Bool
        var date: Date?

        init(_ movie: LibraryBackup.MovieRecord) { (isWatched, date) = (movie.isWatched, movie.watchedDate) }
        init(_ episode: LibraryBackup.EpisodeRecord) { (isWatched, date) = (episode.isWatched, episode.watchedDate) }
        private init(isWatched: Bool, date: Date?) { (self.isWatched, self.date) = (isWatched, date) }

        /// Like a backup import: watched on either side stays watched, with this device's date if it has one.
        func combined(with other: WatchState) -> WatchState {
            guard isWatched else { return other }
            return WatchState(isWatched: true, date: date ?? other.date)
        }
    }
}

// MARK: - Applying a merged library

public extension LibraryService {
    /// Makes the library match a merged snapshot: user state is set exactly, titles and collections missing
    /// from it are deleted, and titles new to this device are created from its metadata. Existing metadata is
    /// left alone, except for IMDb ratings newer than this device's. Returns whether anything changed.
    @discardableResult
    func applySyncedBackup(_ backup: LibraryBackup) throws -> Bool {
        let notes = notesByOwner()
        let spaces = try upsert(backup.spaces, existing: context.fetch(FetchDescriptor<Space>()), key: \.uuid,
                                modelKey: \.uuid) { record in
            let space = Space(name: record.name, symbolName: record.symbolName, colorName: record.colorName)
            space.uuid = record.uuid
            space.createdAt = record.createdAt
            context.insert(space)
            return space
        } update: { space, record in
            assign(space, \.name, record.name)
            assign(space, \.symbolName, record.symbolName)
            assign(space, \.colorName, record.colorName)
        }
        let tags = try upsert(backup.tags, existing: context.fetch(FetchDescriptor<MediaTag>()), key: \.uuid,
                              modelKey: \.uuid) { record in
            let tag = MediaTag(name: record.name, colorName: record.colorName)
            tag.uuid = record.uuid
            tag.createdAt = record.createdAt
            context.insert(tag)
            return tag
        } update: { tag, record in
            assign(tag, \.name, record.name)
            assign(tag, \.colorName, record.colorName)
        }
        try upsert(backup.smartLists, existing: context.fetch(FetchDescriptor<SmartList>()), key: \.uuid,
                   modelKey: \.uuid) { record in
            let list = SmartList(name: record.name, rules: record.rules)
            list.uuid = record.uuid
            list.createdAt = record.createdAt
            list.symbolName = record.symbolName
            list.colorName = record.colorName
            context.insert(list)
            return list
        } update: { list, record in
            assign(list, \.name, record.name)
            assign(list, \.symbolName, record.symbolName)
            assign(list, \.colorName, record.colorName)
            if list.rules != record.rules { list.rules = record.rules }
        }

        var movies = FetchDescriptor<Movie>()
        movies.relationshipKeyPathsForPrefetching = [\.spaces, \.tags]
        try upsert(backup.movies, existing: context.fetch(movies), key: \.tmdbID,
                   modelKey: \.tmdbID, make: makeMovie) { movie, record in
            assign(movie, \.isWatched, record.isWatched)
            assign(movie, \.watchedDate, record.watchedDate)
            assign(movie, \.userRating, record.userRating)
            assign(movie, \.isInBacklog, record.isInBacklog)
            assign(movie, \.isFavorite, record.isFavorite)
            assign(movie, \.addedDate, record.addedDate)
            movie.adoptIMDbRating(from: record)
            setNotes(record.notes, on: notes.movies[movie.persistentModelID]) { $0.movie = movie }
            if Set((movie.spaces ?? []).map(\.uuid)) != Set(record.spaceIDs) { movie.spaces = record.spaceIDs.compactMap { spaces[$0] } }
            if Set((movie.tags ?? []).map(\.uuid)) != Set(record.tagIDs) { movie.tags = record.tagIDs.compactMap { tags[$0] } }
        }

        var shows = FetchDescriptor<TVShow>()
        shows.relationshipKeyPathsForPrefetching = [\.spaces, \.tags]
        try upsert(backup.shows, existing: context.fetch(shows), key: \.tmdbID,
                   modelKey: \.tmdbID, make: makeShow) { show, record in
            assign(show, \.userRating, record.userRating)
            assign(show, \.isInBacklog, record.isInBacklog)
            assign(show, \.isFavorite, record.isFavorite)
            assign(show, \.isAbandoned, record.isAbandoned)
            assign(show, \.addedDate, record.addedDate)
            show.adoptIMDbRating(from: record)
            setNotes(record.notes, on: notes.shows[show.persistentModelID]) { $0.show = show }
            if Set((show.spaces ?? []).map(\.uuid)) != Set(record.spaceIDs) { show.spaces = record.spaceIDs.compactMap { spaces[$0] } }
            if Set((show.tags ?? []).map(\.uuid)) != Set(record.tagIDs) { show.tags = record.tagIDs.compactMap { tags[$0] } }
            setEpisodes(record.seasons, on: show, notes: notes.episodes)
        }

        guard context.hasChanges else { return false }
        save()
        return true
    }

    /// Creates, updates, and deletes models so they match the records one-to-one by key.
    /// `make` inserts the new model.
    @discardableResult
    private func upsert<M: PersistentModel, R, K: Hashable>(_ records: [R], existing: [M], key: KeyPath<R, K>,
                                                             modelKey: KeyPath<M, K>, make: (R) -> M,
                                                             update: (M, R) -> Void) -> [K: M] {
        var byKey: [K: M] = [:]
        for model in existing {
            let k = model[keyPath: modelKey]
            if byKey[k] == nil { byKey[k] = model } else { context.delete(model) } // A duplicate.
        }
        var kept: [K: M] = [:]
        for record in records {
            let k = record[keyPath: key]
            let model = byKey[k] ?? make(record)
            update(model, record)
            kept[k] = model
        }
        for (k, model) in byKey where kept[k] == nil { context.delete(model) }
        return kept
    }

    private func setNotes(_ records: [LibraryBackup.NoteRecord], on existing: @autoclosure () -> [Note]?,
                          attach: (Note) -> Void) {
        let notes = existing() ?? []
        guard !records.isEmpty || !notes.isEmpty else { return }
        let wanted = Dictionary(records.map { (LibrarySync.noteKey($0.createdAt), $0) }) { first, _ in first }
        var present = Set<Int>()
        for note in notes {
            let key = LibrarySync.noteKey(note.createdAt)
            guard let record = wanted[key], present.insert(key).inserted else {
                context.delete(note)
                continue
            }
            assign(note, \.text, record.text)
            assign(note, \.updatedAt, record.updatedAt)
        }
        for (key, record) in wanted where !present.contains(key) {
            let note = Note(text: record.text)
            note.createdAt = record.createdAt
            note.updatedAt = record.updatedAt
            context.insert(note)
            attach(note)
        }
    }

    /// Creates seasons and episodes this device doesn't have yet, and sets each listed episode's user state.
    private func setEpisodes(_ records: [LibraryBackup.SeasonRecord], on show: TVShow,
                             notes episodeNotes: [PersistentIdentifier: [Note]]) {
        var seasons = Dictionary((show.seasons ?? []).map { ($0.seasonNumber, $0) }) { first, _ in first }
        for record in records {
            let season = seasons[record.seasonNumber] ?? makeSeason(record, in: show)
            seasons[record.seasonNumber] = season
            var episodes = Dictionary((season.episodes ?? []).map { ($0.episodeNumber, $0) }) { first, _ in first }
            for episodeRecord in record.episodes {
                let episode = episodes[episodeRecord.episodeNumber] ?? makeEpisode(episodeRecord, in: season)
                episodes[episodeRecord.episodeNumber] = episode
                assign(episode, \.isWatched, episodeRecord.isWatched)
                assign(episode, \.watchedDate, episodeRecord.watchedDate)
                assign(episode, \.userRating, episodeRecord.userRating)
                setNotes(episodeRecord.notes, on: episodeNotes[episode.persistentModelID]) { $0.episode = episode }
            }
        }
    }

    /// Writes only real changes, so a sync that changes nothing doesn't save.
    private func assign<Root: AnyObject, T: Equatable>(_ object: Root, _ keyPath: ReferenceWritableKeyPath<Root, T>, _ value: T) {
        if object[keyPath: keyPath] != value { object[keyPath: keyPath] = value }
    }

    /// Dates from the file have whole seconds; a date within the same second is unchanged.
    private func assign<Root: AnyObject>(_ object: Root, _ keyPath: ReferenceWritableKeyPath<Root, Date?>, _ value: Date?) {
        if object[keyPath: keyPath].map(LibrarySync.noteKey) != value.map(LibrarySync.noteKey) { object[keyPath: keyPath] = value }
    }

    private func assign<Root: AnyObject>(_ object: Root, _ keyPath: ReferenceWritableKeyPath<Root, Date>, _ value: Date) {
        if LibrarySync.noteKey(object[keyPath: keyPath]) != LibrarySync.noteKey(value) { object[keyPath: keyPath] = value }
    }
}
