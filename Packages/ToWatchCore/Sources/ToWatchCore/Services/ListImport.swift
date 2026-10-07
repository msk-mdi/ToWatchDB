import Foundation
import SwiftData

/// A title read from a plain-text list, such as one exported by another tracker:
///
///     MOVIES
///     ======
///     Arrival (2016) - drama, mystery, sciencefiction
///
///     TV SHOWS
///     ========
///     The Sopranos (1999) - crime, drama - 6 season(s), 86 episodes
public struct ListEntry: Hashable, Sendable, Identifiable {
    public enum Kind: Sendable { case movie, show }

    public let kind: Kind
    public let title: String
    public let year: Int?
    /// 1-based line in the file, to point at titles that weren't found.
    public let line: Int

    public var id: Int { line }

    public init(kind: Kind, title: String, year: Int?, line: Int) {
        self.kind = kind
        self.title = title
        self.year = year
        self.line = line
    }

    /// "Arrival (2016)"
    public var label: String { year.map { "\(title) (\($0))" } ?? title }
}

public enum ListImport {
    /// Reads one title per line. "MOVIES" / "TV SHOWS" headings switch the kind (movies until one appears);
    /// underlines, blank lines, bullets, and numbering are skipped. Anything after the year is ignored.
    public static func parse(_ text: String) -> [ListEntry] {
        var kind = ListEntry.Kind.movie
        var entries: [ListEntry] = []
        // `isNewline` takes "\r\n" as one character, so Windows files keep their line numbers. A byte-order mark
        // at the start would otherwise stick to the first line and hide a heading there.
        for (index, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            var line = rawLine.trimmingCharacters(in: .whitespaces.union(["\u{FEFF}"]))
            guard !line.isEmpty, !line.allSatisfy({ "=-_#*~".contains($0) }) else { continue }
            if let heading = heading(line) {
                kind = heading
                continue
            }
            line = line.replacing(/^(?:[-*•·]|\d+[.)])\s+/, with: "")
            // After the year: a separated detail ("- drama"), a bracketed note ("(Director's Cut)"), or plain words.
            if let match = line.firstMatch(of: /^(.+?)\s*\((\d{4})\)(?:\s*[-–—,|:(\[].*|\s+\S.*)?$/) {
                entries.append(ListEntry(kind: kind, title: String(match.1), year: Int(match.2), line: index + 1))
            } else {
                // No year: the title is everything before a " - " detail.
                let title = line.components(separatedBy: " - ")[0].trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { entries.append(ListEntry(kind: kind, title: title, year: nil, line: index + 1)) }
            }
        }
        return entries
    }

    /// A text file's contents: UTF-16 when it starts with that byte-order mark (Windows Notepad's "Unicode"),
    /// otherwise UTF-8, with anything invalid replaced rather than failing.
    public static func decodeText(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let text = String(data: data, encoding: .utf16) {
            return text
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func heading(_ line: String) -> ListEntry.Kind? {
        let word = line.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " #:=-"))
        switch word {
        case "movies", "movie", "films", "film": return .movie
        case "tv shows", "tv show", "tv", "shows", "series", "tv series": return .show
        default: return nil
        }
    }

    /// A search result to match against.
    public struct Candidate: Sendable {
        public let id: Int
        public let titles: [String]
        public let year: Int?

        public init(id: Int, titles: [String], year: Int?) {
            self.id = id
            self.titles = titles
            self.year = year
        }
    }

    /// The candidate that best fits the title and year, or nil if none is convincing.
    /// Lists often carry a regional release year (Princess Mononoke 2022 for a 1997 film), so the title counts
    /// for more than the year. A result whose title doesn't match is only taken when it's TMDB's top result
    /// and its year agrees: a list may use a romanized title ("Tengoku Daimakyo" for "Heavenly Delusion").
    public static func bestMatch(_ candidates: [Candidate], title: String, year: Int?) -> Int? {
        let wanted = normalize(title)
        let literal = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var best: (id: Int, score: Double)?
        for (rank, candidate) in candidates.enumerated() {
            let names = candidate.titles.map(normalize)
            // An exact title outweighs any year: a partial title in the listed year is usually another film.
            let titleScore: Double = if names.contains(wanted) {
                4
            } else if names.contains(where: { !$0.isEmpty && ($0.contains(wanted) || wanted.contains($0)) }) {
                1
            } else {
                0
            }
            let distance: Int? = if let year, let candidateYear = candidate.year { abs(year - candidateYear) } else { nil }
            // Regional release dates are usually a year off, so that's nearly as good as the same year.
            let yearScore: Double = switch distance {
            case 0: 2
            case 1: 1.5
            case let d? where d <= 3: 0.5
            default: 0
            }
            guard titleScore > 0 || (rank == 0 && yearScore >= 1) else { continue }
            // The same title with its punctuation ("In the Mood for Love", not "@ in the mood for love").
            let literalBonus = candidate.titles.contains {
                $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) == literal
            } ? 0.5 : 0
            // TMDB ranks the better-known title first; this settles near-ties without beating a better match.
            let score = titleScore + yearScore + literalBonus - Double(min(rank, 5)) * 0.1
            if score > best?.score ?? -1 { best = (candidate.id, score) }
        }
        return best?.id
    }

    /// Lowercased, without accents or punctuation, "&" read as "and".
    static func normalize(_ title: String) -> String {
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacing("&", with: " and ")
            .replacing("æ", with: "ae")
        let spaced = String(folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " })
        return spaced.split(separator: " ").joined(separator: " ")
    }
}

/// How imported titles are filed.
public enum ListImportMark: String, Sendable, CaseIterable {
    case none, watched, backlog
}

public struct ListImportResult: Sendable {
    public var added = 0
    /// Already in the library; still marked watched or backlog if asked.
    public var alreadyInLibrary = 0
    /// Lines naming a title an earlier line already matched.
    public var duplicates = 0
    public var notFound: [ListEntry] = []
    /// Entries TMDB couldn't be asked about (offline, an invalid token, rate limiting): not the same as not found.
    public var failed: [ListEntry] = []
    /// Why the first failed entry failed.
    public var failureReason: String?
}

extension LibraryService {
    /// Finds each entry on TMDB and adds it, a few at a time, saving once at the end. `progress` gets the
    /// number of entries handled so far.
    public func importList(_ entries: [ListEntry], mark: ListImportMark,
                           progress: (Int) -> Void = { _ in }) async throws -> ListImportResult {
        let client = try requireClient()
        let existingMovies = Set(((try? context.fetch(FetchDescriptor<Movie>())) ?? []).map(\.tmdbID))
        let existingShows = Set(((try? context.fetch(FetchDescriptor<TVShow>())) ?? []).map(\.tmdbID))

        var result = ListImportResult()
        var handled = 0
        var seen: Set<String> = []
        await Self.forEachConcurrently(Array(entries.indices), limit: 4) { index in
            await Self.fetch(entries[index], client: client, existingMovies: existingMovies, existingShows: existingShows)
        } apply: { index, payload in
            handled += 1
            defer { progress(handled) }
            // Every entry lands in exactly one count, so they add up to the number of titles in the list.
            func isFirst(_ key: String) -> Bool {
                if seen.insert(key).inserted { return true }
                result.duplicates += 1
                return false
            }
            switch payload {
            case .notFound:
                result.notFound.append(entries[index])
            case let .failed(reason):
                result.failed.append(entries[index])
                if result.failureReason == nil { result.failureReason = reason }
            case let .existingMovie(id):
                guard isFirst("m\(id)") else { return }
                guard let movie = movie(tmdbID: id) else { return result.notFound.append(entries[index]) }
                result.alreadyInLibrary += 1
                file(movie, mark)
            case let .existingShow(id):
                guard isFirst("s\(id)") else { return }
                guard let show = show(tmdbID: id) else { return result.notFound.append(entries[index]) }
                result.alreadyInLibrary += 1
                file(show, mark)
            case let .movie(detail):
                guard isFirst("m\(detail.id)") else { return }
                result.added += 1
                file(upsertMovie(detail), mark)
            case let .show(detail, seasons):
                guard isFirst("s\(detail.id)") else { return }
                result.added += 1
                file(upsertShow(detail, seasons: seasons), mark)
            }
        }
        result.notFound.sort { $0.line < $1.line }
        result.failed.sort { $0.line < $1.line }
        save()
        return result
    }

    private enum Payload: Sendable {
        case notFound
        /// The request failed: TMDB never said whether it has the title.
        case failed(String)
        case existingMovie(Int), existingShow(Int)
        case movie(TMDBMovieDetail)
        case show(TMDBTVDetail, [TMDBSeasonDetail])
    }

    /// Off the main actor: search (with the year, then without), then download what's new.
    private static func fetch(_ entry: ListEntry, client: TMDBClient,
                              existingMovies: Set<Int>, existingShows: Set<Int>) async -> Payload {
        do {
            return try await match(entry, client: client, existingMovies: existingMovies, existingShows: existingShows)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func match(_ entry: ListEntry, client: TMDBClient,
                              existingMovies: Set<Int>, existingShows: Set<Int>) async throws -> Payload {
        switch entry.kind {
        case .movie:
            func search(_ year: Int?) async throws -> Int? {
                let results = try await client.searchMovies(entry.title, year: year).results
                let candidates = results.map {
                    ListImport.Candidate(id: $0.id, titles: [$0.title, $0.originalTitle].compactMap { $0 },
                                         year: TMDBDate.year($0.releaseDate))
                }
                return ListImport.bestMatch(candidates, title: entry.title, year: entry.year)
            }
            var id = try await search(entry.year)
            if id == nil, entry.year != nil { id = try await search(nil) }
            guard let id else { return .notFound }
            if existingMovies.contains(id) { return .existingMovie(id) }
            return .movie(try await client.movie(id: id))
        case .show:
            func search(_ year: Int?) async throws -> Int? {
                let results = try await client.searchTVShows(entry.title, year: year).results
                let candidates = results.map {
                    ListImport.Candidate(id: $0.id, titles: [$0.name, $0.originalName].compactMap { $0 },
                                         year: TMDBDate.year($0.firstAirDate))
                }
                return ListImport.bestMatch(candidates, title: entry.title, year: entry.year)
            }
            var id = try await search(entry.year)
            if id == nil, entry.year != nil { id = try await search(nil) }
            guard let id else { return .notFound }
            if existingShows.contains(id) { return .existingShow(id) }
            let (detail, seasons) = try await client.tvShowWithSeasons(id: id)
            return .show(detail, seasons)
        }
    }

    /// Never un-marks: importing a list as "not watched" leaves titles you've already watched alone.
    private func file(_ movie: Movie, _ mark: ListImportMark) {
        switch mark {
        case .none: break
        case .watched:
            guard !movie.isWatched else { return }
            movie.isWatched = true
            movie.watchedDate = nil // The list doesn't say when.
            movie.isInBacklog = false
        case .backlog:
            if !movie.isWatched { movie.isInBacklog = true }
        }
    }

    private func file(_ show: TVShow, _ mark: ListImportMark) {
        switch mark {
        case .none: break
        case .watched:
            for episode in show.airedEpisodes() where !episode.isWatched {
                episode.isWatched = true
                episode.watchedDate = nil
            }
            show.isInBacklog = false
        case .backlog:
            show.isInBacklog = true
        }
    }
}
