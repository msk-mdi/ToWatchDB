import AppIntents
import SwiftData
import ToWatchCore

// Library items as App Intents entities, so Siri and Shortcuts can ask "which movie?" and search by name.
// Queries run on the main actor against the app's shared container.

struct MovieEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Movie"
    static let defaultQuery = MovieQuery()

    let id: Int
    let title: String
    let year: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: year.map { "\($0)" })
    }

    init(_ movie: Movie) {
        id = movie.tmdbID
        title = movie.title
        year = movie.releaseDate?.yearString
    }
}

struct MovieQuery: EntityStringQuery {
    func entities(for identifiers: [Int]) async throws -> [MovieEntity] {
        await MainActor.run {
            // One service: building it reads (and on Mac decrypts) the TMDB token.
            let library = SharedLibrary.service
            return identifiers.compactMap { library.movie(tmdbID: $0).map(MovieEntity.init) }
        }
    }

    func entities(matching string: String) async throws -> [MovieEntity] {
        await MainActor.run {
            // Matched in the store instead of loading every movie.
            let descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.title.localizedStandardContains(string) })
            return ((try? SharedLibrary.container.mainContext.fetch(descriptor)) ?? []).map(MovieEntity.init)
        }
    }

    func suggestedEntities() async throws -> [MovieEntity] {
        await MainActor.run {
            var descriptor = FetchDescriptor<Movie>(sortBy: [SortDescriptor(\.addedDate, order: .reverse)])
            descriptor.fetchLimit = 30
            return ((try? SharedLibrary.container.mainContext.fetch(descriptor)) ?? []).map(MovieEntity.init)
        }
    }
}

struct ShowEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "TV Show"
    static let defaultQuery = ShowQuery()

    let id: Int
    let name: String
    let detail: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: detail.map { "\($0)" })
    }

    @MainActor
    init(_ show: TVShow) {
        self.init(show, next: show.nextEpisodeToWatch())
    }

    /// `next`: the show's next episode to watch, when the caller already found it.
    @MainActor
    init(_ show: TVShow, next: Episode?) {
        id = show.tmdbID
        name = show.name
        detail = next.map { "Next: \($0.code)" } ?? show.firstAirDate?.yearString
    }
}

struct ShowQuery: EntityStringQuery {
    func entities(for identifiers: [Int]) async throws -> [ShowEntity] {
        await MainActor.run {
            let library = SharedLibrary.service
            return identifiers.compactMap { library.show(tmdbID: $0).map { ShowEntity($0) } }
        }
    }

    func entities(matching string: String) async throws -> [ShowEntity] {
        await MainActor.run {
            let descriptor = FetchDescriptor<TVShow>(predicate: #Predicate { $0.name.localizedStandardContains(string) })
            return ((try? SharedLibrary.container.mainContext.fetch(descriptor)) ?? []).map { ShowEntity($0) }
        }
    }

    /// Shows with an episode to watch come first: they're what people ask about.
    func suggestedEntities() async throws -> [ShowEntity] {
        await MainActor.run {
            let shows = (try? SharedLibrary.container.mainContext.fetch(FetchDescriptor<TVShow>())) ?? []
            // Each show's next episode found once, not twice per comparison.
            return shows
                .map { (show: $0, next: $0.nextEpisodeToWatch()) }
                .sorted { ($0.next != nil ? 0 : 1, $0.show.name) < ($1.next != nil ? 0 : 1, $1.show.name) }
                .prefix(30)
                .map { ShowEntity($0.show, next: $0.next) }
        }
    }
}

/// Spaces, smart lists, and tags share one shape: a named collection with an ID.
struct CollectionEntity: AppEntity {
    enum Kind: String, Codable, Sendable { case space, smartList, tag }

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Collection"
    static let defaultQuery = CollectionQuery()

    let id: String
    let name: String
    let kind: Kind
    let uuid: UUID
    let symbol: String

    var displayRepresentation: DisplayRepresentation {
        let kindLabel: LocalizedStringResource = switch kind {
        case .space: "Space"
        case .smartList: "Smart List"
        case .tag: "Tag"
        }
        return DisplayRepresentation(title: "\(name)", subtitle: kindLabel, image: .init(systemName: symbol))
    }

    var scope: LibraryScope {
        switch kind {
        case .space: .space(uuid)
        case .smartList: .smartList(uuid)
        case .tag: .tag(uuid)
        }
    }

    init(kind: Kind, uuid: UUID, name: String, symbol: String) {
        self.kind = kind
        self.uuid = uuid
        self.name = name
        self.symbol = symbol
        id = "\(kind.rawValue):\(uuid.uuidString)"
    }
}

struct CollectionQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [CollectionEntity] {
        let all = try await suggestedEntities()
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    func entities(matching string: String) async throws -> [CollectionEntity] {
        try await suggestedEntities().filter { $0.name.localizedStandardContains(string) }
    }

    func suggestedEntities() async throws -> [CollectionEntity] {
        await MainActor.run {
            let context = SharedLibrary.container.mainContext
            let spaces = ((try? context.fetch(FetchDescriptor<Space>(sortBy: [SortDescriptor(\.name)]))) ?? [])
                .map { CollectionEntity(kind: .space, uuid: $0.uuid, name: $0.name, symbol: $0.symbolName) }
            let lists = ((try? context.fetch(FetchDescriptor<SmartList>(sortBy: [SortDescriptor(\.name)]))) ?? [])
                .map { CollectionEntity(kind: .smartList, uuid: $0.uuid, name: $0.name, symbol: $0.symbolName) }
            let tags = ((try? context.fetch(FetchDescriptor<MediaTag>(sortBy: [SortDescriptor(\.name)]))) ?? [])
                .map { CollectionEntity(kind: .tag, uuid: $0.uuid, name: $0.name, symbol: "tag") }
            return spaces + lists + tags
        }
    }
}

/// Built-in lists an action can open.
enum AppList: String, AppEnum {
    case nextToWatch, upcoming, backlog, watched, library, stats

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "List"
    static let caseDisplayRepresentations: [AppList: DisplayRepresentation] = [
        .nextToWatch: DisplayRepresentation(title: "Next to Watch", image: .init(systemName: "play.circle")),
        .upcoming: DisplayRepresentation(title: "Upcoming", image: .init(systemName: "calendar")),
        .backlog: DisplayRepresentation(title: "Backlog", image: .init(systemName: "tray.full")),
        .watched: DisplayRepresentation(title: "Watched", image: .init(systemName: "checkmark.circle")),
        .library: DisplayRepresentation(title: "Library", image: .init(systemName: "square.grid.2x2")),
        .stats: DisplayRepresentation(title: "Stats", image: .init(systemName: "chart.bar.xaxis")),
    ]

    var destination: IntentRouter.Destination {
        switch self {
        case .nextToWatch: .tab(.nextToWatch)
        case .upcoming: .tab(.upcoming)
        case .backlog: .scope(.backlog)
        case .watched: .scope(.watched)
        case .library: .tab(.all)
        case .stats: .tab(.stats)
        }
    }
}

enum StatsPeriodOption: String, AppEnum {
    case thisWeek, thisMonth, last30Days, thisYear, lastYear, allTime

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Period"
    static let caseDisplayRepresentations: [StatsPeriodOption: DisplayRepresentation] = [
        .thisWeek: "This Week", .thisMonth: "This Month", .last30Days: "Last 30 Days",
        .thisYear: "This Year", .lastYear: "Last Year", .allTime: "All Time",
    ]

    var period: StatsPeriod {
        let year = StatsPeriod.calendar.component(.year, from: .now)
        return switch self {
        case .thisWeek: .thisWeek
        case .thisMonth: .thisMonth
        case .last30Days: .lastDays(30)
        case .thisYear: .year(year)
        case .lastYear: .year(year - 1)
        case .allTime: .allTime
        }
    }
}
