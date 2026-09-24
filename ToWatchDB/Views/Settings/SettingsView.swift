import SwiftData
import SwiftUI
import ToWatchCore

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Query private var movies: [Movie]
    @Query private var shows: [TVShow]

    @State private var tokenDraft = ""
    /// Settings runs its own panels: on macOS it's a separate window from the one handling File menu requests.
    @State private var fileRequest: LibraryFileRequest?
    @State private var testResult: String?
    @State private var isTesting = false

    private static let languages: [(code: String, name: String)] = [
        ("", "System Default"), ("en-US", "English"), ("fr-FR", "Français"), ("es-ES", "Español"),
        ("de-DE", "Deutsch"), ("it-IT", "Italiano"), ("pt-BR", "Português (Brasil)"), ("nl-NL", "Nederlands"),
        ("ja-JP", "日本語"), ("ko-KR", "한국어"), ("zh-CN", "中文 (简体)"), ("ar-SA", "العربية"),
    ]

    var body: some View {
        @Bindable var appState = appState

        Form {
            Section("TMDB") {
                LabeledContent("Access Token") {
                    Text(tokenStatus).foregroundStyle(appState.token == nil ? .red : .secondary)
                }
                SecureField("Custom read access token", text: $tokenDraft, prompt: Text("Paste a v4 read access token"))
                HStack {
                    Button("Save Token") {
                        appState.setTokenOverride(tokenDraft)
                        tokenDraft = ""
                    }
                    .disabled(tokenDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    if appState.tokenOverride != nil {
                        Button("Remove Custom Token", role: .destructive) { appState.setTokenOverride(nil) }
                    }
                    Spacer()
                    if isTesting { ProgressView().controlSize(.small) }
                    Button("Test Connection") { test() }
                        .disabled(appState.client == nil || isTesting)
                }
                .rowButtonStyle()
                if let testResult {
                    Text(testResult).font(.callout).foregroundStyle(.secondary)
                }
                Picker("Language", selection: $appState.language) {
                    ForEach(Self.languages, id: \.code) { Text($0.name).tag($0.code) }
                }
                Text("Titles, overviews, and episode names are fetched in this language when TMDB has a translation. Refresh the library to update existing titles.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Where to Watch Country", selection: $appState.watchRegion) {
                    ForEach(Self.regions, id: \.self) { code in
                        Text(Locale.current.localizedString(forRegionCode: code) ?? code).tag(code)
                    }
                }
            }

            Section("Library") {
                LabeledContent("Movies", value: movies.count.formatted())
                LabeledContent("TV Shows", value: shows.count.formatted())
                HStack {
                    Button("Refresh All Titles") { Task { await appState.refreshLibrary(force: true) } }
                        .disabled(appState.isRefreshing || appState.client == nil)
                    if appState.isRefreshing { ProgressView().controlSize(.small) }
                }
                .rowButtonStyle()
                Text("Ongoing shows and unreleased movies refresh automatically every 12 hours at launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                #if os(iOS)
                Button("Export Backup…", systemImage: "square.and.arrow.up") { fileRequest = .exportBackup }
                Button("Export as CSV…", systemImage: "tablecells") { fileRequest = .exportCSV }
                Button("Import Backup…", systemImage: "square.and.arrow.down") { fileRequest = .importBackup }
                #else
                HStack {
                    Button("Export Backup…") { fileRequest = .exportBackup }
                    Button("Export as CSV…") { fileRequest = .exportCSV }
                    Spacer()
                    Button("Import Backup…") { fileRequest = .importBackup }
                }
                #endif
            } header: {
                Text("Backup")
            } footer: {
                Text("A backup holds your whole library: titles, watch history, ratings, notes, spaces, tags, and smart lists. Importing merges into what's here, so nothing is lost or duplicated. CSV is for spreadsheets and can't be imported.")
            }

            Section("About") {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "film.stack").font(.largeTitle).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ToWatchDB").font(.headline)
                        Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
                            .font(.callout)
                        Link("themoviedb.org", destination: URL(string: "https://www.themoviedb.org")!)
                            .font(.callout)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .libraryFileTransfers($fileRequest)
        #if os(macOS)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        #else
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { appState.isShowingSettings = false }
            }
        }
        #endif
    }

    /// Every ISO country, sorted by localized name, for the Where to Watch default.
    private static let regions: [String] = Locale.Region.isoRegions
        .filter { $0.subRegions.isEmpty && $0.identifier.count == 2 && $0.identifier.allSatisfy(\.isLetter) }
        .map(\.identifier)
        .sorted {
            (Locale.current.localizedString(forRegionCode: $0) ?? $0)
                .localizedStandardCompare(Locale.current.localizedString(forRegionCode: $1) ?? $1) == .orderedAscending
        }

    private var tokenStatus: String {
        if appState.tokenOverride != nil { return "Custom token (Keychain)" }
        if appState.hasBundledToken { return "Built-in token" }
        return "Missing"
    }

    private func test() {
        guard let client = appState.client else { return }
        isTesting = true
        testResult = nil
        Task {
            do {
                let page = try await client.trendingMovies()
                testResult = "Connected. \(page.results.count) trending movies received."
            } catch {
                testResult = error.localizedDescription
            }
            isTesting = false
        }
    }
}

private extension View {
    /// In an iOS Form, a row with several buttons fires all of them on tap unless they're borderless.
    func rowButtonStyle() -> some View {
        #if os(iOS)
        buttonStyle(.borderless)
        #else
        self
        #endif
    }
}
