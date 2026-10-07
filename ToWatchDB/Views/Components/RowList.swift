import SwiftUI

/// A page of plain rows: a `List` on iOS; on macOS, a lazy stack in a scroll view.
/// A Mac `List` is an `NSTableView`. Showing or hiding one cost about 20 ms of main-thread time on every page
/// switch, and its rows about as much again, which froze the top bar's animation mid-slide (CODEBASE §7).
struct RowList<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        #if os(macOS)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) { content }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        #else
        List { content }
        #endif
    }
}

extension View {
    /// A row of a `RowList`. On macOS it gets list-like insets and a hover highlight.
    func rowListRow() -> some View {
        modifier(RowListRow())
    }
}

/// A section header of a `RowList`, styled like a Mac list's.
struct RowListHeader<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        #if os(macOS)
        HStack { content }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 4)
            // A List's section headers are headings to VoiceOver; these replace them on Mac.
            .accessibilityAddTraits(.isHeader)
        #else
        HStack { content }
        #endif
    }
}

private struct RowListRow: ViewModifier {
    #if os(macOS)
    @State private var isHovered = false
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(isHovered ? 0.6 : 0), in: .rect(cornerRadius: 8))
            .contentShape(.rect)
            .onHover { isHovered = $0 }
            .accessibilityElement(children: .contain)
        #else
        content
        #endif
    }
}
