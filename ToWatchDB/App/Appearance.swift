import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// How Mac and iPad lay out the app's sections. iPhone always uses its compact tab bar.
enum NavigationLayout: String, CaseIterable, Identifiable {
    /// Every list, space, tag, and smart list in a sidebar that stays open.
    case sidebar
    /// The main sections as tabs along the top; the library scopes are a picker inside Library.
    case topBar

    static let storageKey = "navigationLayout"

    var id: Self { self }

    var label: String {
        switch self {
        case .sidebar: "Sidebar"
        case .topBar: "Top Bar"
        }
    }
}

/// A theme color, used both for the accent color and for the app icon.
/// Coral is the original look and stays the default.
enum ThemeColor: String, CaseIterable, Identifiable {
    case coral, orange, yellow, green, teal, blue, indigo, purple, pink, graphite

    static let accentKey = "accentColor"
    static let appIconKey = "appIcon"

    var id: Self { self }

    var label: String {
        switch self {
        case .coral: "Coral"
        case .graphite: "Graphite"
        default: rawValue.capitalized
        }
    }

    var color: Color {
        switch self {
        case .coral: .accentColor
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .teal: .teal
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .graphite: .gray
        }
    }

    /// Icon artwork shown in Settings, and used as the Dock icon on macOS.
    var iconPreviewName: String { "IconPreview-\(label)" }

    /// Alternate icon set name (iOS); `nil` is the primary icon.
    var alternateIconName: String? { self == .coral ? nil : "AppIcon-\(label)" }

    /// Switches the app icon. iOS changes the Home Screen icon (and shows a system confirmation);
    /// macOS can only change the Dock icon while the app runs, since the bundle's icon is signed.
    @MainActor
    func applyAsAppIcon() {
        #if os(macOS)
        NSApp.applicationIconImage = self == .coral ? nil : NSImage(named: iconPreviewName)
        #else
        guard UIApplication.shared.supportsAlternateIcons,
              UIApplication.shared.alternateIconName != alternateIconName else { return }
        UIApplication.shared.setAlternateIconName(alternateIconName)
        #endif
    }
}

extension EnvironmentValues {
    /// The user's accent color, for places that need a `Color` rather than the `.tint` style (charts, gradients).
    @Entry var themeColor: Color = .accentColor
}

extension View {
    /// Applies the accent color the user picked in Settings. Each scene's root calls this.
    func themed() -> some View {
        modifier(ThemeModifier())
    }
}

private struct ThemeModifier: ViewModifier {
    @AppStorage(ThemeColor.accentKey) private var accent: ThemeColor = .coral

    func body(content: Content) -> some View {
        content
            .tint(accent.color)
            .environment(\.themeColor, accent.color)
    }
}
