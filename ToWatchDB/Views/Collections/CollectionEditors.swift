import SwiftData
import SwiftUI
import ToWatchCore

/// What the shared collection editor sheet is editing. `assigning` adds the title to a newly created space or tag.
enum CollectionEditorTarget: Identifiable {
    case newSpace(assigning: LibraryTitle? = nil)
    case editSpace(Space)
    case newTag(assigning: LibraryTitle? = nil)
    case editTag(MediaTag)
    case newSmartList
    case editSmartList(SmartList)

    var id: String {
        switch self {
        case .newSpace: "new-space"
        case let .editSpace(space): "space-\(space.uuid)"
        case .newTag: "new-tag"
        case let .editTag(tag): "tag-\(tag.uuid)"
        case .newSmartList: "new-smart-list"
        case let .editSmartList(list): "smart-list-\(list.uuid)"
        }
    }
}

extension View {
    /// Presents the collection editor requested through `AppState.collectionEditor`.
    func collectionEditorSheet(_ appState: AppState) -> some View {
        modifier(CollectionEditorPresenter(appState: appState))
    }
}

/// The request is app-wide, but the sheet belongs in one window: the active one on macOS (a title window or
/// the main window), the first to see it on iPad. Without this, every open window showed its own editor.
private struct CollectionEditorPresenter: ViewModifier {
    let appState: AppState
    @State private var target: CollectionEditorTarget?
    #if os(macOS)
    @Environment(\.appearsActive) private var appearsActive
    #endif

    func body(content: Content) -> some View {
        content
            .onChange(of: appState.collectionEditor?.id, initial: true) { claim() }
            // A request made while this window's sheet was open waited for a change that never came, then
            // popped up on its own the next time the window became active.
            .onChange(of: target == nil) { claim() }
            #if os(macOS)
            .onChange(of: appearsActive) { claim() }
            #endif
            .sheet(item: $target) { target in
                NavigationStack {
                    switch target {
                    case let .newSpace(title): SpaceEditor(space: nil, assigning: title)
                    case let .editSpace(space): SpaceEditor(space: space)
                    case let .newTag(title): TagEditor(tag: nil, assigning: title)
                    case let .editTag(tag): TagEditor(tag: tag)
                    case .newSmartList: SmartListEditor(list: nil)
                    case let .editSmartList(list): SmartListEditor(list: list)
                    }
                }
                .environment(appState)
                #if os(macOS)
                .frame(minWidth: 460, minHeight: 520)
                #endif
            }
    }

    private func claim() {
        #if os(macOS)
        guard appearsActive else { return }
        #endif
        guard target == nil, let pending = appState.collectionEditor else { return }
        appState.collectionEditor = nil
        target = pending
    }
}

// MARK: - Space

private struct SpaceEditor: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let space: Space?
    var assigning: LibraryTitle?

    @State private var name = ""
    @State private var symbol = "star"
    @State private var colorName = "blue"

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text("Family Night"))
                LabeledContent("Preview") {
                    CollectionChip(name: name.isEmpty ? "Space" : name, symbol: symbol, color: CollectionPalette.color(colorName))
                }
            }
            Section("Color") { ColorSwatchPicker(selection: $colorName) }
            Section("Icon") { SymbolPicker(selection: $symbol, tint: CollectionPalette.color(colorName)) }
        }
        .formStyle(.grouped)
        .navigationTitle(space == nil ? "New Space" : "Edit Space")
        .editorToolbar(canSave: !name.trimmingCharacters(in: .whitespaces).isEmpty, save: save)
        .onAppear {
            guard let space else { return }
            name = space.name
            symbol = space.symbolName
            colorName = space.colorName
        }
    }

    private func save() {
        let library = appState.library
        if let space {
            library.update(space, name: name, symbolName: symbol, colorName: colorName)
        } else if let created = library.createSpace(name: name, symbolName: symbol, colorName: colorName), let assigning {
            library.toggle(assigning, in: created)
        }
        dismiss()
    }
}

// MARK: - Tag

private struct TagEditor: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let tag: MediaTag?
    var assigning: LibraryTitle?

    @State private var name = ""
    @State private var colorName = "gray"

    var body: some View {
        // Once per redraw: each check fetches every tag.
        let isNameTaken = isNameTaken
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text("Rewatch"))
                LabeledContent("Preview") {
                    CollectionChip(name: name.isEmpty ? "Tag" : name, color: CollectionPalette.color(colorName))
                }
            } footer: {
                // Tags are matched by name, so two with one name would be merged unpredictably by import and sync.
                if isNameTaken {
                    if tag == nil {
                        Text("There's already a tag with this name. Saving uses it.")
                    } else {
                        Text("There's already a tag with this name.").foregroundStyle(.red)
                    }
                }
            }
            Section("Color") { ColorSwatchPicker(selection: $colorName) }
        }
        .formStyle(.grouped)
        .navigationTitle(tag == nil ? "New Tag" : "Edit Tag")
        .editorToolbar(canSave: !name.trimmingCharacters(in: .whitespaces).isEmpty && !(isNameTaken && tag != nil), save: save)
        .onAppear {
            guard let tag else { return }
            name = tag.name
            colorName = tag.colorName
        }
    }

    private var isNameTaken: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let existing = appState.library.tag(named: trimmed) else { return false }
        return existing.persistentModelID != tag?.persistentModelID
    }

    private func save() {
        let library = appState.library
        if let tag {
            library.update(tag, name: name, colorName: colorName)
        } else if let created = library.createTag(name: name, colorName: colorName), let assigning,
                  !library.isTagged(assigning, created) {
            library.toggle(created, on: assigning)
        }
        dismiss()
    }
}

// MARK: - Smart list

private struct SmartListEditor: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Space.name) private var spaces: [Space]
    @Query(sort: \MediaTag.name) private var tags: [MediaTag]
    let list: SmartList?

    @State private var name = ""
    @State private var symbol = "wand.and.stars"
    @State private var colorName = "purple"
    @State private var rules = SmartListRules()
    @State private var genres: [String] = []

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text("Unwatched Sci-Fi"))
            }

            Section("Include") {
                Picker("Type", selection: $rules.media) {
                    ForEach(SmartListRules.Media.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Only titles in the backlog", isOn: $rules.backlogOnly)
                Toggle("Only favorites", isOn: $rules.favoritesOnly)
            }

            Section {
                ForEach(WatchStatus.allCases) { status in
                    Toggle(isOn: membership(status, in: \.statuses)) {
                        Label(status.label, systemImage: status.symbol)
                    }
                }
            } header: {
                Text("Watch Status")
            } footer: {
                Text("None selected means any status.")
            }

            Section("Your Rating") {
                Picker("At least", selection: $rules.minimumRating) {
                    Text("Any").tag(Double?.none)
                    ForEach(1...5, id: \.self) { stars in
                        Text(String(repeating: "★", count: stars)).tag(Optional(Double(stars * 2)))
                    }
                }
            }

            Section {
                yearField("From", value: $rules.releasedFrom)
                yearField("Through", value: $rules.releasedThrough)
            } header: {
                Text("Release Year")
            } footer: {
                if !hasValidYears { Text("“From” can’t be after “Through”.").foregroundStyle(.red) }
            }

            if !genres.isEmpty {
                Section {
                    ForEach(genres, id: \.self) { genre in
                        Toggle(genre, isOn: membership(genre, in: \.genres))
                    }
                } header: {
                    Text("Genres")
                } footer: {
                    Text("Matches any selected genre.")
                }
            }

            if !spaces.isEmpty {
                Section("Spaces") {
                    ForEach(spaces) { space in
                        Toggle(isOn: membership(space.uuid, in: \.spaceIDs)) {
                            Label(space.name, systemImage: space.symbolName).foregroundStyle(space.color)
                        }
                    }
                }
            }

            if !tags.isEmpty {
                Section("Tags") {
                    ForEach(tags) { tag in
                        Toggle(isOn: membership(tag.uuid, in: \.tagIDs)) {
                            CollectionChip(name: tag.name, color: tag.color)
                        }
                    }
                }
            }

            Section("Appearance") {
                ColorSwatchPicker(selection: $colorName)
                SymbolPicker(selection: $symbol, tint: CollectionPalette.color(colorName))
            }
        }
        .formStyle(.grouped)
        .navigationTitle(list == nil ? "New Smart List" : "Edit Smart List")
        .editorToolbar(canSave: !name.trimmingCharacters(in: .whitespaces).isEmpty && hasValidYears, save: save)
        .onAppear {
            genres = appState.library.allGenres()
            guard let list else { return }
            name = list.name
            symbol = list.symbolName
            colorName = list.colorName
            rules = list.rules
            // Keep genres the rules use even if no title has them anymore, so they can still be turned off.
            genres = Array(Set(genres).union(rules.genres)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
    }

    private func membership<Value: Hashable>(_ value: Value, in keyPath: WritableKeyPath<SmartListRules, Set<Value>>) -> Binding<Bool> {
        Binding(
            get: { rules[keyPath: keyPath].contains(value) },
            set: { isOn in
                if isOn { rules[keyPath: keyPath].insert(value) } else { rules[keyPath: keyPath].remove(value) }
            }
        )
    }

    /// A text field that updates the rules on every keystroke. A formatted value field only committed on Return
    /// or leaving the field, so a year typed just before clicking Save was dropped.
    private func yearField(_ label: String, value: Binding<Int?>) -> some View {
        TextField(label, text: Binding(get: { value.wrappedValue.map(String.init) ?? "" },
                                       set: { value.wrappedValue = Int($0.filter(\.isASCII).filter(\.isNumber)) }),
                  prompt: Text("Any"))
            #if os(iOS)
            .keyboardType(.numberPad)
            #endif
    }

    private var hasValidYears: Bool {
        guard let from = rules.releasedFrom, let through = rules.releasedThrough else { return true }
        return from <= through
    }

    private func save() {
        let library = appState.library
        // Spaces and tags deleted since this list was made can't be shown or matched; drop them.
        var rules = rules
        rules.spaceIDs.formIntersection(spaces.map(\.uuid))
        rules.tagIDs.formIntersection(tags.map(\.uuid))
        if let list {
            library.update(list, name: name, symbolName: symbol, colorName: colorName, rules: rules)
        } else {
            library.createSmartList(name: name, symbolName: symbol, colorName: colorName, rules: rules)
        }
        dismiss()
    }
}

private extension View {
    func editorToolbar(canSave: Bool, save: @escaping () -> Void) -> some View {
        modifier(EditorToolbar(canSave: canSave, save: save))
    }
}

private struct EditorToolbar: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    let canSave: Bool
    let save: () -> Void

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save).disabled(!canSave)
            }
        }
    }
}
