import SwiftUI

extension View {
    /// Shows an empty state centered in the view, the same on every screen, even when the view is a scroll
    /// view with a header (scope picker, chips) at the top. Only the message itself takes clicks, so the
    /// header stays usable around it.
    func centeredEmptyState(_ isShown: Bool, @ViewBuilder content: () -> some View) -> some View {
        // A scroll view with nothing (or only a small picker) in it can size itself to its content on macOS,
        // which squeezed the message into a narrow column; fill the space so it centers in the whole page.
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if isShown {
                    content()
                        .fixedSize(horizontal: false, vertical: true)
                        .padding()
                }
            }
    }
}
