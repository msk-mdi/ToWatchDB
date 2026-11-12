import SwiftData
import SwiftUI
import ToWatchCore

/// A library kept on this device that can be merged back: a copy made before a sync deleted a large part of the
/// library, or a store that couldn't be opened at launch and was moved aside.
struct KeptLibrary: Identifiable, Hashable {
    enum Kind {
        case beforeSync
        case unreadableStore
    }

    /// The copy's file, or the folder the store was moved to.
    let url: URL
    let date: Date
    let kind: Kind
    var id: URL { url }

    /// Newest first. None in a sample-data run, which must not touch the real library's files.
    @MainActor
    static func all() -> [KeptLibrary] {
        guard !SharedLibrary.isInMemory else { return [] }
        let copies = LibraryCopies.all().map { KeptLibrary(url: $0.url, date: $0.date, kind: .beforeSync) }
        let stores = SharedLibrary.unreadableStores().map { KeptLibrary(url: $0.folder, date: $0.date, kind: .unreadableStore) }
        return (copies + stores).sorted { $0.date > $1.date }
    }

    /// The library it holds, read off the main thread: it's a whole library.
    func backup() async throws -> LibraryBackup {
        try await Task.detached(priority: .userInitiated) { [url, kind] in
            switch kind {
            case .beforeSync: try BackupCoding.decode(Data(contentsOf: url))
            case .unreadableStore: try SharedLibrary.backup(ofStoreIn: url)
            }
        }.value
    }
}

/// Lists the kept libraries in Settings, when there are any, to merge one back or delete it.
struct KeptLibrariesSection: View {
    @Environment(AppState.self) private var appState
    @State private var kept = KeptLibrary.all()
    @State private var restoring: KeptLibrary?
    @State private var deleting: KeptLibrary?
    @State private var message: (title: String, text: String)?

    var body: some View {
        if !kept.isEmpty {
            Section {
                ForEach(kept) { row($0) }
            } header: {
                Text("Kept Libraries")
            } footer: {
                Text("Your library is copied here before a sync deletes a large part of it, and a library that couldn't be opened is kept too. Restoring merges one into what's here, so nothing is lost or duplicated; with Dropbox sync on, the titles it brings back return on your other devices.")
            }
            .confirmationDialog("Delete this kept library?", isPresented: isDeleting, titleVisibility: .visible, presenting: deleting) { library in
                Button("Delete", role: .destructive) {
                    try? FileManager.default.removeItem(at: library.url)
                    kept = KeptLibrary.all()
                }
            } message: { _ in
                Text("It can't be restored afterwards. Your current library isn't changed.")
            }
            .alert(message?.title ?? "", isPresented: hasMessage) {
                Button("OK") {}
            } message: {
                Text(message?.text ?? "")
            }
        }
    }

    private var isDeleting: Binding<Bool> {
        Binding { deleting != nil } set: { if !$0 { deleting = nil } }
    }

    private var hasMessage: Binding<Bool> {
        Binding { message != nil } set: { if !$0 { message = nil } }
    }

    private func row(_ library: KeptLibrary) -> some View {
        LabeledContent {
            HStack {
                if restoring == library { ProgressView().controlSize(.small) }
                Button("Restore") { restore(library) }
                Button("Delete", role: .destructive) { deleting = library }
            }
            .rowButtonStyle()
            .disabled(restoring != nil)
        } label: {
            Text(library.kind == .beforeSync ? "Before a Sync" : "Couldn't Be Opened")
            Text(library.date.formatted(date: .abbreviated, time: .shortened))
        }
    }

    private func restore(_ library: KeptLibrary) {
        restoring = library
        Task {
            defer { restoring = nil }
            do {
                let backup = try await library.backup()
                message = ("Library Restored", try await appState.library.importBackupInSlices(backup).description)
            } catch {
                // A store that couldn't be opened at launch usually still can't: it needs the version that made it.
                message = ("Couldn't Restore the Library", library.kind == .unreadableStore
                    ? "This version of the app can't open it (\(error.localizedDescription)). It's kept, so a version that can open it can restore it."
                    : error.localizedDescription)
            }
        }
    }
}
