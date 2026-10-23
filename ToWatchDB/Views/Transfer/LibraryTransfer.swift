import SwiftData
import SwiftUI
import ToWatchCore
import UniformTypeIdentifiers

/// A backup, CSV export, or import the user asked for, from Settings or the File menu.
enum LibraryFileRequest: Hashable {
    /// `importList`: a plain-text list of titles ("Arrival (2016)"), looked up on TMDB.
    case exportBackup, exportCSV, importBackup, importList
}

/// In-memory file handed to the system save panel.
struct ExportFile: FileDocument {
    static let readableContentTypes: [UTType] = [.json, .commaSeparatedText]
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) { data = configuration.file.regularFileContents ?? Data() }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

extension View {
    /// Runs the save/open panels for a library file request and reports the result.
    func libraryFileTransfers(_ request: Binding<LibraryFileRequest?>) -> some View {
        modifier(LibraryFileTransfers(request: request))
    }
}

private struct LibraryFileTransfers: ViewModifier {
    @Environment(AppState.self) private var appState
    @Binding var request: LibraryFileRequest?

    @State private var document: ExportFile?
    @State private var contentType: UTType = .json
    @State private var filename = ""
    @State private var isExporting = false
    @State private var isImporting = false
    /// What the open panel is for: a backup (JSON) or a list of titles (text).
    @State private var importKind: LibraryFileRequest = .importBackup
    @State private var listDraft: ListImportDraft?
    /// Shown here, not through `appState.errorMessage`: that alert is on the main window, which is behind the
    /// Settings window on Mac (or missing), so a failed import from Settings showed nothing.
    @State private var message: (title: String, text: String)?
    #if os(macOS)
    @Environment(\.appearsActive) private var appearsActive
    #endif

    func body(content: Content) -> some View {
        content
            .onChange(of: request, initial: true) { claim() }
            #if os(macOS)
            .onChange(of: appearsActive) { claim() }
            #endif
            .fileExporter(isPresented: $isExporting, document: document, contentType: contentType,
                          defaultFilename: filename) { result in
                if case let .failure(error) = result { showError(error.localizedDescription) }
                document = nil
            }
            // One open panel for both imports: a second fileImporter on the same view doesn't present.
            .fileImporter(isPresented: $isImporting,
                          allowedContentTypes: importKind == .importList ? [.plainText, .text] : [.json]) { result in
                switch result {
                case let .success(url): importKind == .importList ? readList(from: url) : importBackup(from: url)
                case let .failure(error): showError(error.localizedDescription)
                }
            }
            .sheet(item: $listDraft) { ListImportSheet(draft: $0) }
            .alert(message?.title ?? "", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(message?.text ?? "")
            }
    }

    /// Every window has this modifier, so only one takes a request: the active window on macOS, the first
    /// to see it on iPad. Reading the binding (not the onChange value) lets a later window see it's taken.
    private func claim() {
        #if os(macOS)
        guard appearsActive else { return }
        #endif
        guard let pending = request else { return }
        request = nil
        start(pending)
    }

    private func start(_ request: LibraryFileRequest) {
        let today = Date.now.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        switch request {
        case .exportBackup:
            // Snapshotted and encoded off the main thread, from what's saved: it walks every title and episode.
            let library = appState.library
            if library.context.hasChanges { library.save() }
            let container = appState.container
            Task {
                do {
                    let data = try await Task.detached(priority: .userInitiated) {
                        try BackupCoding.encoder.encode(LibraryService.makeBackup(in: ModelContext(container)))
                    }.value
                    document = ExportFile(data: data)
                    contentType = .json
                    filename = "ToWatchDB Backup \(today).json"
                    isExporting = true
                } catch {
                    showError(error.localizedDescription)
                }
            }
        case .exportCSV:
            // Off the main thread, from what's saved, like the backup: it walks every show's episodes.
            let library = appState.library
            if library.context.hasChanges { library.save() }
            let container = appState.container
            Task {
                do {
                    let csv = try await Task.detached(priority: .userInitiated) {
                        try LibraryService.exportCSV(in: ModelContext(container))
                    }.value
                    // The byte-order mark makes Excel read the file as UTF-8 rather than garbling accented titles.
                    document = ExportFile(data: Data(("\u{FEFF}" + csv).utf8))
                    contentType = .commaSeparatedText
                    filename = "ToWatchDB \(today).csv"
                    isExporting = true
                } catch {
                    showError(error.localizedDescription)
                }
            }
        case .importBackup, .importList:
            if request == .importList, appState.client == nil {
                showError("Add your TMDB token in Settings first: titles in the list are looked up on TMDB.")
                return
            }
            importKind = request
            isImporting = true
        }
    }

    private func showError(_ text: String) {
        message = ("Something went wrong", text)
    }

    private func readList(from url: URL) {
        Task {
            let isScoped = url.startAccessingSecurityScopedResource()
            defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
            do {
                // Off the main thread like a backup: a large file froze the window while it was read and parsed.
                let entries = try await Task.detached(priority: .userInitiated) {
                    ListImport.parse(ListImport.decodeText(try Data(contentsOf: url)))
                }.value
                guard !entries.isEmpty else {
                    showError("No titles found in “\(url.lastPathComponent)”. Put one title per line, like “Arrival (2016)”.")
                    return
                }
                listDraft = ListImportDraft(fileName: url.lastPathComponent, entries: entries)
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    private func importBackup(from url: URL) {
        Task {
            // Files picked in the open panel are outside the sandbox until explicitly accessed.
            let isScoped = url.startAccessingSecurityScopedResource()
            defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
            do {
                // Reading and decoding the whole library happens off the main thread; only applying it stays on it.
                let backup = try await Task.detached(priority: .userInitiated) {
                    try BackupCoding.decode(Data(contentsOf: url))
                }.value
                message = ("Import Complete", try appState.library.importBackup(backup).description)
            } catch {
                showError(error.localizedDescription)
            }
        }
    }
}
