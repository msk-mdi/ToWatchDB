import SwiftUI
import ToWatchCore
import UniformTypeIdentifiers

/// A backup, CSV export, or import the user asked for, from Settings or the File menu.
enum LibraryFileRequest: Hashable {
    case exportBackup, exportCSV, importBackup
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
    @State private var resultMessage: String?

    func body(content: Content) -> some View {
        content
            .onChange(of: request) { _, newValue in
                guard let newValue else { return }
                request = nil
                start(newValue)
            }
            .fileExporter(isPresented: $isExporting, document: document, contentType: contentType,
                          defaultFilename: filename) { result in
                if case let .failure(error) = result { appState.errorMessage = error.localizedDescription }
                document = nil
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
                switch result {
                case let .success(url): importBackup(from: url)
                case let .failure(error): appState.errorMessage = error.localizedDescription
                }
            }
            .alert("Import Complete", isPresented: Binding(
                get: { resultMessage != nil },
                set: { if !$0 { resultMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(resultMessage ?? "")
            }
    }

    private func start(_ request: LibraryFileRequest) {
        let today = Date.now.formatted(.iso8601.year().month().day())
        do {
            switch request {
            case .exportBackup:
                document = ExportFile(data: try appState.library.exportBackupData())
                contentType = .json
                filename = "ToWatchDB Backup \(today).json"
                isExporting = true
            case .exportCSV:
                document = ExportFile(data: Data(try appState.library.exportCSV().utf8))
                contentType = .commaSeparatedText
                filename = "ToWatchDB \(today).csv"
                isExporting = true
            case .importBackup:
                isImporting = true
            }
        } catch {
            appState.errorMessage = error.localizedDescription
        }
    }

    private func importBackup(from url: URL) {
        // Files picked in the open panel are outside the sandbox until explicitly accessed.
        let isScoped = url.startAccessingSecurityScopedResource()
        defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            resultMessage = try appState.library.importBackup(data: data).description
        } catch {
            appState.errorMessage = error.localizedDescription
        }
    }
}
