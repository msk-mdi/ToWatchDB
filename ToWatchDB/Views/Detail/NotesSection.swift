import SwiftUI
import ToWatchCore

/// Notes attached to a movie, show, or episode, with inline add, edit, and delete.
struct NotesSection: View {
    @Environment(AppState.self) private var appState
    let notes: [Note]
    let add: (String) -> Void

    @State private var draft = ""
    @State private var editing: Note?
    @State private var editText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Notes").font(.title3.bold())

            ForEach(notes.sorted { $0.createdAt > $1.createdAt }) { note in
                VStack(alignment: .leading, spacing: 4) {
                    if editing == note {
                        TextField("Note", text: $editText, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(commitEdit)
                        HStack {
                            Button("Save", action: commitEdit).keyboardShortcut(.defaultAction)
                            Button("Cancel") { editing = nil }
                        }
                        .controlSize(.small)
                    } else {
                        Text(note.text).textSelection(.enabled)
                        Text(note.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .frame(maxWidth: 760, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
                .contextMenu {
                    Button("Edit", systemImage: "pencil") {
                        editText = note.text
                        editing = note
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        appState.library.delete(note)
                    }
                }
            }

            HStack {
                TextField("Add a note…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commitDraft)
                Button("Add", action: commitDraft)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .frame(maxWidth: 760)
        }
    }

    private func commitDraft() {
        add(draft)
        draft = ""
    }

    private func commitEdit() {
        if let editing, !editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appState.library.update(editing, text: editText)
        }
        editing = nil
    }
}

/// Picks the date something was watched, or no date at all.
struct WatchDateSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let onSave: (Date?) -> Void

    @State private var date = Date.now
    @State private var unknownDate = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Mark “\(title)” as Watched").font(.headline)
            DatePicker("Watched on", selection: $date, in: ...Date.now, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .disabled(unknownDate)
            Toggle("I don't remember the date", isOn: $unknownDate)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Mark Watched") {
                    onSave(unknownDate ? nil : date)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 320)
    }
}
