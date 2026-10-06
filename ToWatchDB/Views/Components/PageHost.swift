import SwiftUI

extension EnvironmentValues {
    /// False for a page kept alive offscreen by `PageHost`. Such a page must not put its title, toolbar items,
    /// search field, or Title-menu target into the window.
    @Entry var isActivePage = true
}

/// Shows the selected page and keeps the last few visited ones alive, hidden, like a native tab view.
/// Rebuilding a page from scratch on every switch (view graph, layout, toolbar) took 100–350 ms on macOS,
/// a visible stall; a kept page comes back by flipping its visibility.
struct PageHost<Page: View>: View {
    let selected: AppTab
    /// How many hidden pages to keep. Hidden pages still update when the library changes, so not all of them.
    var capacity = 8
    @ViewBuilder let page: (AppTab) -> Page

    /// Most recently shown last.
    @State private var recent: [AppTab] = []
    /// Each page's pushed details. A hidden page is popped to its root: every stack with a pushed page adds a
    /// Back button to the one window toolbar, and AppKit throws on a second one (a duplicate toolbar item).
    @State private var paths: [AppTab: NavigationPath] = [:]

    var body: some View {
        // The selected page is always included, so the first frame after a switch isn't empty.
        let pages = recent.contains(selected) ? recent : recent + [selected]
        ZStack {
            ForEach(pages, id: \.self) { tab in
                let isActive = tab == selected
                NavigationStack(path: path(for: tab)) { page(tab) }
                    .environment(\.isActivePage, isActive)
                    .opacity(isActive ? 1 : 0)
                    .allowsHitTesting(isActive)
                    .accessibilityHidden(!isActive)
                    .zIndex(isActive ? 1 : 0)
            }
        }
        .onChange(of: selected, initial: true) { _, tab in
            paths = paths.filter { $0.key == tab }
            recent.removeAll { $0 == tab }
            recent.append(tab)
            if recent.count > capacity { recent.removeFirst(recent.count - capacity) }
        }
    }

    private func path(for tab: AppTab) -> Binding<NavigationPath> {
        Binding(get: { paths[tab] ?? NavigationPath() }, set: { paths[tab] = $0 })
    }
}

extension View {
    /// `navigationTitle` that only the visible page sets.
    func pageTitle(_ title: String) -> some View {
        modifier(PageTitle(title: title))
    }

    /// `toolbar` whose items only the visible page shows.
    func pageToolbar<Items: ToolbarContent>(@ToolbarContentBuilder _ items: () -> Items) -> some View {
        modifier(PageToolbar(items: items()))
    }
}

private struct PageTitle: ViewModifier {
    @Environment(\.isActivePage) private var isActive
    let title: String

    func body(content: Content) -> some View {
        // Hidden pages set no title at all (an empty one still won). The title sits on an empty background
        // view, so adding or removing it doesn't rebuild the page.
        content.background {
            if isActive { Color.clear.navigationTitle(title) }
        }
    }
}

private struct PageToolbar<Items: ToolbarContent>: ViewModifier {
    @Environment(\.isActivePage) private var isActive
    let items: Items

    func body(content: Content) -> some View {
        content.toolbar {
            if isActive { items }
        }
    }
}
