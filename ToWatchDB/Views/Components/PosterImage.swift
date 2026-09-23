import SwiftUI
import ToWatchCore

/// A 2:3 poster with a placeholder while loading or when TMDB has no artwork.
struct PosterImage: View {
    let path: String?
    var size: TMDBImageSize = .poster
    var cornerRadius: CGFloat = 8

    var body: some View {
        Color.secondary.opacity(0.15)
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay {
                AsyncImage(url: TMDBImage.url(path, size: size), transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    case .failure:
                        placeholder
                    case .empty:
                        if path == nil { placeholder } else { ProgressView().controlSize(.small) }
                    @unknown default:
                        placeholder
                    }
                }
            }
            .clipShape(.rect(cornerRadius: cornerRadius))
    }

    private var placeholder: some View {
        Image(systemName: "film")
            .font(.title)
            .foregroundStyle(.tertiary)
    }
}

/// Wide backdrop image that fades into the window background.
struct BackdropImage: View {
    let path: String?

    var body: some View {
        AsyncImage(url: TMDBImage.url(path, size: .backdrop)) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            LinearGradient(colors: [.accentColor.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom)
        }
        .frame(height: 320)
        .frame(maxWidth: .infinity)
        .clipped()
        .overlay {
            LinearGradient(colors: [.clear, .clear, backgroundColor], startPoint: .top, endPoint: .bottom)
        }
    }

    private var backgroundColor: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}
