import SwiftUI
import ToWatchCore

/// A plain-text list of titles read from a file, waiting to be imported.
struct ListImportDraft: Identifiable {
    let id = UUID()
    let fileName: String
    let entries: [ListEntry]
}

/// Imports a list of titles ("Arrival (2016) - drama…", one per line) by finding each one on TMDB.
struct ListImportSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let draft: ListImportDraft

    @State private var mark: ListImportMark = .none
    @State private var phase: Phase = .ready
    /// Shown by this sheet: the app's error alert is on the main window, which may be behind Settings.
    @State private var errorMessage: String?

    private enum Phase {
        case ready
        case importing(done: Int)
        case finished(ListImportResult)
    }

    var body: some View {
        NavigationStack {
            Form {
                switch phase {
                case .ready: options
                case let .importing(done): importing(done)
                case let .finished(result): summary(result)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Import List")
            .toolbar { toolbar }
        }
        .alert("Couldn't Import the List", isPresented: Binding { errorMessage != nil } set: { if !$0 { errorMessage = nil } }) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
        #if os(macOS)
        .frame(width: 480, height: 440)
        #endif
        .interactiveDismissDisabled(isImporting)
    }

    private var movieCount: Int { draft.entries.count { $0.kind == .movie } }
    private var showCount: Int { draft.entries.count - movieCount }

    private var isImporting: Bool {
        if case .importing = phase { true } else { false }
    }

    // MARK: Phases

    @ViewBuilder
    private var options: some View {
        Section {
            LabeledContent("File", value: draft.fileName)
            LabeledContent("Movies", value: movieCount.formatted())
            LabeledContent("TV Shows", value: showCount.formatted())
        } footer: {
            Text("Each title is looked up on TMDB by its name and year. Titles already in your library aren't added twice.")
        }
        Section {
            Picker("Add as", selection: $mark) {
                Text("Not Watched").tag(ListImportMark.none)
                Text("Watched").tag(ListImportMark.watched)
                Text("Backlog").tag(ListImportMark.backlog)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            Text("Add As")
        } footer: {
            switch mark {
            case .none: Text("Titles are added without changing what you've watched.")
            case .watched: Text("Movies and every aired episode of the shows are marked watched, without a date.")
            case .backlog: Text("Titles go to your Backlog, unless you've already watched them.")
            }
        }
    }

    private func importing(_ done: Int) -> some View {
        Section {
            ProgressView(value: Double(done), total: Double(max(draft.entries.count, 1))) {
                Text("Finding titles on TMDB…")
            } currentValueLabel: {
                Text("\(done) of \(draft.entries.count)")
            }
        }
    }

    @ViewBuilder
    private func summary(_ result: ListImportResult) -> some View {
        Section {
            LabeledContent("Added", value: result.added.formatted())
            LabeledContent("Already in Library", value: result.alreadyInLibrary.formatted())
            LabeledContent("Not Found", value: result.notFound.count.formatted())
            if result.duplicates > 0 {
                LabeledContent("Listed Twice", value: result.duplicates.formatted())
            }
            if !result.failed.isEmpty {
                LabeledContent("Couldn't Reach TMDB", value: result.failed.count.formatted())
            }
        }
        if !result.failed.isEmpty {
            Section {
                ForEach(result.failed) { entry in
                    LabeledContent(entry.label, value: "Line \(entry.line)")
                }
            } header: {
                Text("Couldn't Reach TMDB")
            } footer: {
                Text("\(result.failureReason.map { $0 + " " } ?? "")Import the list again later to add these: titles already added aren't duplicated.")
            }
        }
        if !result.notFound.isEmpty {
            Section {
                ForEach(result.notFound) { entry in
                    LabeledContent(entry.label, value: "Line \(entry.line)")
                }
            } header: {
                Text("Not Found")
            } footer: {
                Text("Search for these yourself: TMDB may list them under another title.")
            }
        }
    }

    // MARK: Actions

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        switch phase {
        case .ready:
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Import") { start() }.disabled(draft.entries.isEmpty)
            }
        case .importing:
            ToolbarItem(placement: .confirmationAction) { Button("Import") {}.disabled(true) }
        case .finished:
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
    }

    private func start() {
        phase = .importing(done: 0)
        Task {
            do {
                let result = try await appState.library.importList(draft.entries, mark: mark) { done in
                    phase = .importing(done: done)
                }
                phase = .finished(result)
            } catch {
                phase = .ready
                errorMessage = error.localizedDescription
            }
        }
    }
}
