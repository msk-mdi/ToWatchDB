import SwiftData
import SwiftUI
import ToWatchCore

/// "Spaces" and "Tags" submenus with a checkmark per membership, for poster context menus.
struct CollectionMenus: View {
    @Environment(AppState.self) private var appState
    @Query(sort: \Space.name) private var spaces: [Space]
    @Query(sort: \MediaTag.name) private var tags: [MediaTag]
    let title: LibraryTitle

    var body: some View {
        let library = appState.library
        Menu("Spaces", systemImage: "square.stack") {
            ForEach(spaces) { space in
                Toggle(isOn: Binding(get: { library.isIn(title, space) }, set: { _ in library.toggle(title, in: space) })) {
                    Label(space.name, systemImage: space.symbolName)
                }
            }
            if !spaces.isEmpty { Divider() }
            Button("New Space…", systemImage: "plus") { appState.collectionEditor = .newSpace(assigning: title) }
        }
        Menu("Tags", systemImage: "tag") {
            ForEach(tags) { tag in
                Toggle(tag.name, isOn: Binding(get: { library.isTagged(title, tag) }, set: { _ in library.toggle(tag, on: title) }))
            }
            if !tags.isEmpty { Divider() }
            Button("New Tag…", systemImage: "plus") { appState.collectionEditor = .newTag(assigning: title) }
        }
    }
}

/// Spaces and tags section on a detail page.
struct CollectionsSection: View {
    @Environment(AppState.self) private var appState
    let title: LibraryTitle

    var body: some View {
        let spaces = title.spaces.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let tags = title.tags.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Spaces & Tags").font(.title3.bold())
                Spacer()
                Menu {
                    CollectionMenus(title: title)
                } label: {
                    Label("Organize", systemImage: "square.stack.3d.up")
                }
                .fixedSize()
            }
            .frame(maxWidth: 760)
            if spaces.isEmpty && tags.isEmpty {
                Text("Not in any space and no tags yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(spaces) { space in
                        CollectionChip(name: space.name, symbol: space.symbolName, color: space.color)
                            .contextMenu {
                                Button("Remove from \(space.name)", systemImage: "minus.circle") {
                                    appState.library.toggle(title, in: space)
                                }
                            }
                    }
                    ForEach(tags) { tag in
                        CollectionChip(name: tag.name, color: tag.color)
                            .contextMenu {
                                Button("Remove Tag", systemImage: "minus.circle") { appState.library.toggle(tag, on: title) }
                            }
                    }
                }
            }
        }
    }
}

/// Wraps chips onto as many lines as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let last = rows.count - 1
            rows[last].width += (rows[last].indices.isEmpty ? 0 : spacing) + size.width
            rows[last].height = max(rows[last].height, size.height)
            rows[last].indices.append(index)
        }
        return rows
    }
}

/// iPhone: spaces, smart lists, and tags as a scrolling row under the Library scope picker.
struct CollectionShortcuts: View {
    @Query(sort: \Space.name) private var spaces: [Space]
    @Query(sort: \SmartList.name) private var smartLists: [SmartList]
    @Query(sort: \MediaTag.name) private var tags: [MediaTag]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                NavigationLink(value: StatsRoute()) {
                    CollectionChip(name: "Stats", symbol: "chart.bar.xaxis", color: .accentColor)
                }
                ForEach(spaces) { space in
                    NavigationLink(value: LibraryScope.space(space.uuid)) {
                        CollectionChip(name: space.name, symbol: space.symbolName, color: space.color)
                    }
                }
                ForEach(smartLists) { list in
                    NavigationLink(value: LibraryScope.smartList(list.uuid)) {
                        CollectionChip(name: list.name, symbol: list.symbolName, color: list.color)
                    }
                }
                ForEach(tags) { tag in
                    NavigationLink(value: LibraryScope.tag(tag.uuid)) {
                        CollectionChip(name: tag.name, color: tag.color)
                    }
                }
                NavigationLink(value: OrganizeRoute()) {
                    CollectionChip(name: "Organize", symbol: "square.stack.3d.up", color: .secondary)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
        }
        .scrollIndicators(.hidden)
    }
}

/// Navigation value for the Organize screen.
struct OrganizeRoute: Hashable {}

/// Navigation value for Stats, pushed from the iPhone Library tab.
struct StatsRoute: Hashable {}

/// Create, edit, and delete spaces, smart lists, and tags.
struct OrganizeView: View {
    @Environment(AppState.self) private var appState
    @Query(sort: \Space.name) private var spaces: [Space]
    @Query(sort: \SmartList.name) private var smartLists: [SmartList]
    @Query(sort: \MediaTag.name) private var tags: [MediaTag]
    @State private var pendingDeletion: PendingDeletion?

    private struct PendingDeletion: Identifiable {
        let id = UUID()
        let name: String
        let delete: () -> Void
    }

    var body: some View {
        List {
            Section {
                ForEach(spaces) { space in
                    row(name: space.name, symbol: space.symbolName, color: space.color, count: space.itemCount,
                        scope: .space(space.uuid), edit: .editSpace(space)) {
                        appState.library.delete(space)
                    }
                }
            } header: {
                header("Spaces", add: .newSpace())
            } footer: {
                Text("Curated collections you fill yourself.")
            }

            Section {
                ForEach(smartLists) { list in
                    row(name: list.name, symbol: list.symbolName, color: list.color, count: nil,
                        scope: .smartList(list.uuid), edit: .editSmartList(list)) {
                        appState.library.delete(list)
                    }
                }
            } header: {
                header("Smart Lists", add: .newSmartList)
            } footer: {
                Text("Update automatically from rules like status, genre, rating, or tags.")
            }

            Section {
                ForEach(tags) { tag in
                    row(name: tag.name, symbol: "tag.fill", color: tag.color, count: tag.itemCount,
                        scope: .tag(tag.uuid), edit: .editTag(tag)) {
                        appState.library.delete(tag)
                    }
                }
            } header: {
                header("Tags", add: .newTag())
            }
        }
        .navigationTitle("Organize")
        .confirmationDialog("Delete “\(pendingDeletion?.name ?? "")”?", isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        ), presenting: pendingDeletion) { pending in
            Button("Delete", role: .destructive) { pending.delete() }
        } message: { _ in
            Text("Titles stay in your library.")
        }
    }

    private func header(_ title: String, add: CollectionEditorTarget) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button("Add", systemImage: "plus") { appState.collectionEditor = add }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
    }

    private func row(name: String, symbol: String, color: Color, count: Int?, scope: LibraryScope,
                     edit: CollectionEditorTarget, delete: @escaping () -> Void) -> some View {
        NavigationLink(value: scope) {
            HStack {
                Label {
                    Text(name)
                } icon: {
                    Image(systemName: symbol).foregroundStyle(color)
                }
                Spacer()
                if let count {
                    Text(count.formatted()).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .contextMenu {
            Button("Edit…", systemImage: "pencil") { appState.collectionEditor = edit }
            Button("Delete…", systemImage: "trash", role: .destructive) {
                pendingDeletion = PendingDeletion(name: name, delete: delete)
            }
        }
        .swipeActions {
            Button("Delete", systemImage: "trash") { pendingDeletion = PendingDeletion(name: name, delete: delete) }
                .tint(.red)
            Button("Edit", systemImage: "pencil") { appState.collectionEditor = edit }
        }
    }
}
