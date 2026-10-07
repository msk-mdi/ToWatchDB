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

    /// Downloads in progress, so views showing the same image (a title on two pages, an actor in two casts)
    /// share one download and one decode.
    private var inFlight: [URL: Task<Entry, Error>] = [:]
    private let lock = NSLock()

    /// Fetches (through the shared URL cache) and decodes off the main thread.
    func load(_ url: URL) async throws -> Entry {
        if let image = image(for: url) { return Entry(image) }
        let task = lock.withLock {
            if let task = inFlight[url] { return task }
            // Unstructured, so one view scrolling away (cancelling its wait) doesn't cancel the others'.
            let task = Task.detached(priority: .userInitiated) { [self] in
                defer { lock.withLock { inFlight[url] = nil } }
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(
                          source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
                      ) else { throw URLError(.cannotDecodeContentData) }
                let entry = Entry(image)
                store(entry, for: url)
                return entry
            }
            inFlight[url] = task
            return task
        }
        // A download that a view stops waiting for (scrolled away) still finishes into the cache, so scrolling
        // back finds it.
        return try await task.value
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
        guard let url else {
            // An image left from a previous URL would keep showing instead of the placeholder.
            loaded = nil
            failed = false
            return
        }
        if ImageCache.shared.image(for: url) != nil {
            // The body already draws it from the cache; only clear an image left from a previous URL.
            if loaded != nil { loaded = nil }
            return
        }
        loaded = nil
        failed = false
        do {
            let entry = try await ImageCache.shared.load(url)
            // Waiting on the shared download ignores cancellation: the URL changed meanwhile, and this older
            // image would replace the new one.
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.15)) { loaded = entry.image }
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
            // Scrolled away or the page closed; not a failure.
        } catch {
            failed = true
        }
    }
}
