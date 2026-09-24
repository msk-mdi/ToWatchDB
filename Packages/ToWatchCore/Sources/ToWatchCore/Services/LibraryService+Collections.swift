import Foundation
import SwiftData

/// A movie or show, for operations that apply to either.
public enum LibraryTitle {
    case movie(Movie)
    case show(TVShow)

    public var spaces: [Space] {
        switch self {
        case let .movie(movie): movie.spaces ?? []
        case let .show(show): show.spaces ?? []
        }
    }

    public var tags: [MediaTag] {
        switch self {
        case let .movie(movie): movie.tags ?? []
        case let .show(show): show.tags ?? []
        }
    }
}

public extension LibraryService {
    // MARK: Spaces

    @discardableResult
    func createSpace(name: String, symbolName: String = "star", colorName: String = "blue") -> Space? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let space = Space(name: trimmed, symbolName: symbolName, colorName: colorName)
        context.insert(space)
        save()
        return space
    }

    func update(_ space: Space, name: String, symbolName: String, colorName: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { space.name = trimmed }
        space.symbolName = symbolName
        space.colorName = colorName
        save()
    }

    func space(uuid: UUID) -> Space? {
        var descriptor = FetchDescriptor<Space>(predicate: #Predicate { $0.uuid == uuid })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func isIn(_ title: LibraryTitle, _ space: Space) -> Bool {
        title.spaces.contains { $0.persistentModelID == space.persistentModelID }
    }

    /// Adds the title to the space, or removes it if it's already there.
    func toggle(_ title: LibraryTitle, in space: Space) {
        switch title {
        case let .movie(movie): movie.spaces = Self.toggled(space, in: movie.spaces)
        case let .show(show): show.spaces = Self.toggled(space, in: show.spaces)
        }
        save()
    }

    // MARK: Tags

    @discardableResult
    func createTag(name: String, colorName: String = "gray") -> MediaTag? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Tags are matched by name when typed, so reuse an existing one rather than creating a twin.
        if let existing = tag(named: trimmed) { return existing }
        let tag = MediaTag(name: trimmed, colorName: colorName)
        context.insert(tag)
        save()
        return tag
    }

    func update(_ tag: MediaTag, name: String, colorName: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { tag.name = trimmed }
        tag.colorName = colorName
        save()
    }

    func tag(named name: String) -> MediaTag? {
        ((try? context.fetch(FetchDescriptor<MediaTag>())) ?? [])
            .first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    func tag(uuid: UUID) -> MediaTag? {
        var descriptor = FetchDescriptor<MediaTag>(predicate: #Predicate { $0.uuid == uuid })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func isTagged(_ title: LibraryTitle, _ tag: MediaTag) -> Bool {
        title.tags.contains { $0.persistentModelID == tag.persistentModelID }
    }

    /// Adds the tag to the title, or removes it if it's already there.
    func toggle(_ tag: MediaTag, on title: LibraryTitle) {
        switch title {
        case let .movie(movie): movie.tags = Self.toggled(tag, in: movie.tags)
        case let .show(show): show.tags = Self.toggled(tag, in: show.tags)
        }
        save()
    }

    // MARK: Smart lists

    @discardableResult
    func createSmartList(name: String, symbolName: String = "wand.and.stars", colorName: String = "purple",
                         rules: SmartListRules) -> SmartList? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let list = SmartList(name: trimmed, rules: rules)
        list.symbolName = symbolName
        list.colorName = colorName
        context.insert(list)
        save()
        return list
    }

    func update(_ list: SmartList, name: String, symbolName: String, colorName: String, rules: SmartListRules) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { list.name = trimmed }
        list.symbolName = symbolName
        list.colorName = colorName
        list.rules = rules
        save()
    }

    func smartList(uuid: UUID) -> SmartList? {
        var descriptor = FetchDescriptor<SmartList>(predicate: #Predicate { $0.uuid == uuid })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Every genre in the library, for building smart-list rules.
    func allGenres() -> [String] {
        let movies = (try? context.fetch(FetchDescriptor<Movie>())) ?? []
        let shows = (try? context.fetch(FetchDescriptor<TVShow>())) ?? []
        return Set(movies.flatMap(\.genres) + shows.flatMap(\.genres)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func toggled<M: PersistentModel>(_ model: M, in list: [M]?) -> [M] {
        var list = list ?? []
        if let index = list.firstIndex(where: { $0.persistentModelID == model.persistentModelID }) {
            list.remove(at: index)
        } else {
            list.append(model)
        }
        return list
    }
}
