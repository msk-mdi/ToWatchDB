import ImageIO
import SwiftUI

/// Decoded TMDB images kept in memory. `AsyncImage` keeps nothing between appearances: every time a page was
/// rebuilt, each poster went back to its placeholder, waited for the URL cache, decoded on the main thread,
/// and faded in again. With this cache a poster seen before draws on the first frame.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    /// A CGImage behind a class, so it can cross from the decoding task and live in NSCache.
    final class Entry: @unchecked Sendable {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let cache: NSCache<NSURL, Entry> = {
        let cache = NSCache<NSURL, Entry>()
        cache.totalCostLimit = 256 << 20
        return cache
    }()

    func image(for url: URL) -> CGImage? {
        cache.object(forKey: url as NSURL)?.image
    }

    func store(_ entry: Entry, for url: URL) {
        cache.setObject(entry, forKey: url as NSURL, cost: entry.image.bytesPerRow * entry.image.height)
    }

    /// Fetches (through the shared URL cache) and decodes off the main thread.
    func load(_ url: URL) async throws -> Entry {
        if let image = image(for: url) { return Entry(image) }
        let (data, _) = try await URLSession.shared.data(from: url)
        let entry = try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(
                      source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
                  ) else { throw URLError(.cannotDecodeContentData) }
            return Entry(image)
        }.value
        store(entry, for: url)
        return entry
    }
}

/// A remote image backed by `ImageCache`. Cached images appear immediately; only fresh downloads fade in.
struct RemoteImage<Content: View, Placeholder: View>: View {
    let url: URL?
    @ViewBuilder let content: (Image) -> Content
    /// Called with `true` while loading, `false` when there's no image to show.
    @ViewBuilder let placeholder: (_ isLoading: Bool) -> Placeholder

    @State private var loaded: CGImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image = loaded ?? url.flatMap(ImageCache.shared.image(for:)) {
                content(Image(decorative: image, scale: 1))
            } else {
                placeholder(url != nil && !failed)
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else { return }
        if let cached = ImageCache.shared.image(for: url) {
            loaded = cached
            return
        }
        loaded = nil
        failed = false
        do {
            let entry = try await ImageCache.shared.load(url)
            withAnimation(.easeOut(duration: 0.15)) { loaded = entry.image }
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
            // Scrolled away or the page closed; not a failure.
        } catch {
            failed = true
        }
    }
}
