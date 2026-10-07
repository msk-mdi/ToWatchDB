import SwiftUI

extension View {
    /// Shows `appState.errorMessage` in this window.
    func errorAlert(_ appState: AppState) -> some View {
        modifier(ErrorAlert(appState: appState))
    }
}

/// The error is app-wide, but the alert belongs in one window: the active one on macOS, the first to see it on
/// iPad. Only the main window had the alert, so a failure in a title window showed nothing until the main
/// window came back.
private struct ErrorAlert: ViewModifier {
    let appState: AppState
    @State private var message: String?
    #if os(macOS)
    @Environment(\.appearsActive) private var appearsActive
    #endif

    func body(content: Content) -> some View {
        content
            .onChange(of: appState.errorMessage, initial: true) { claim() }
            .onChange(of: message == nil) { claim() }
            #if os(macOS)
            .onChange(of: appearsActive) { claim() }
            #endif
            .alert("Something went wrong", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
    }

    private func claim() {
        #if os(macOS)
        guard appearsActive else { return }
        #endif
        guard message == nil, let pending = appState.errorMessage else { return }
        appState.errorMessage = nil
        message = pending
    }
}
