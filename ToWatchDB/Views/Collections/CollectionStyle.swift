import SwiftUI
import ToWatchCore

/// Named colors for spaces, tags, and smart lists. Stored by name so they survive sync and theme changes.
enum CollectionPalette {
    static let names = ["red", "orange", "yellow", "green", "mint", "teal", "cyan", "blue", "indigo", "purple", "pink", "brown", "gray"]

    static func color(_ name: String) -> Color {
        switch name {
        case "red": .red
        case "orange": .orange
        case "yellow": .yellow
        case "green": .green
        case "mint": .mint
        case "teal": .teal
        case "cyan": .cyan
        case "blue": .blue
        case "indigo": .indigo
        case "purple": .purple
        case "pink": .pink
        case "brown": .brown
        default: .gray
        }
    }

    static let symbols = [
        "star", "heart", "film", "tv", "popcorn", "sparkles", "flame", "bolt", "moon.stars", "sun.max",
        "house", "person.2", "figure.2.and.child.holdinghands", "theatermasks", "music.note", "gamecontroller",
        "book", "globe", "trophy", "gift", "sportscourt", "leaf", "pawprint", "airplane", "brain", "crown",
        "flag", "bookmark", "clock", "wand.and.stars",
    ]
}

extension Space { var color: Color { CollectionPalette.color(colorName) } }
extension MediaTag { var color: Color { CollectionPalette.color(colorName) } }
extension SmartList { var color: Color { CollectionPalette.color(colorName) } }

struct ColorSwatchPicker: View {
    @Binding var selection: String

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 30), spacing: 10)], spacing: 10) {
            ForEach(CollectionPalette.names, id: \.self) { name in
                Button {
                    selection = name
                } label: {
                    Circle()
                        .fill(CollectionPalette.color(name))
                        .frame(width: 26, height: 26)
                        .overlay {
                            if selection == name {
                                Circle().strokeBorder(.primary, lineWidth: 2).padding(-4)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(name.capitalized)
                .accessibilityAddTraits(selection == name ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}

struct SymbolPicker: View {
    @Binding var selection: String
    let tint: Color

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 38), spacing: 8)], spacing: 8) {
            ForEach(CollectionPalette.symbols, id: \.self) { symbol in
                Button {
                    selection = symbol
                } label: {
                    Image(systemName: symbol)
                        .font(.title3)
                        .frame(width: 38, height: 38)
                        .foregroundStyle(selection == symbol ? .white : tint)
                        .background(selection == symbol ? tint : tint.opacity(0.12), in: .rect(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(symbol)
                .accessibilityAddTraits(selection == symbol ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}

/// A capsule showing a space or tag on detail pages.
struct CollectionChip: View {
    let name: String
    var symbol: String?
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
            } else {
                Circle().fill(color).frame(width: 8, height: 8)
            }
            Text(name)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(symbol == nil ? Color.primary : color)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(color.opacity(0.15), in: .capsule)
    }
}
