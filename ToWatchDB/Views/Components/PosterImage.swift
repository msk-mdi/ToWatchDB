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
                RemoteImage(url: TMDBImage.url(path, size: size)) { image in
                    image.resizable().scaledToFill()
                } placeholder: { isLoading in
                    // While loading, the tinted box alone: a spinner on every poster read as lag.
                    if !isLoading { placeholder }
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
    @Environment(\.themeColor) private var themeColor
    let path: String?
    var height: CGFloat = 320

    var body: some View {
        RemoteImage(url: TMDBImage.url(path, size: .backdrop)) { image in
            image.resizable().scaledToFill()
        } placeholder: { _ in
            LinearGradient(colors: [themeColor.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom)
        }
        .frame(height: height)
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
